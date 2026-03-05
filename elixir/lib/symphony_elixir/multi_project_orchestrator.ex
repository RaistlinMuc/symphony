defmodule SymphonyElixir.MultiProjectOrchestrator do
  @moduledoc """
  Multi-project polling orchestrator for GitHub and GitLab repositories.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Project, ProjectRegistry, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @default_retry_after_ms 60_000
  @max_output_bytes 10_000

  defmodule State do
    @moduledoc false
    defstruct [
      :poll_interval_ms,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      project_states: %{},
      running_jobs: %{}
    ]
  end

  @type job_key :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.name(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server \\ __MODULE__, timeout \\ 5_000) do
    if Process.whereis(server) do
      GenServer.call(server, :snapshot, timeout)
    else
      :unavailable
    end
  catch
    :exit, _reason -> :timeout
  end

  @spec request_refresh(GenServer.name()) :: map() | :unavailable
  def request_refresh(server \\ __MODULE__) do
    if Process.whereis(server) do
      GenServer.call(server, :refresh)
    else
      :unavailable
    end
  end

  @impl true
  def init(_opts) do
    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      next_poll_due_at_ms: System.monotonic_time(:millisecond),
      poll_check_in_progress: false,
      project_states: %{},
      running_jobs: %{}
    }

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    send(self(), :run_poll_cycle)
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, %State{} = state) do
    state = poll_projects(state)
    now = System.monotonic_time(:millisecond)
    next_due = now + state.poll_interval_ms
    schedule_tick(state.poll_interval_ms)

    {:noreply, %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_due}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    {job_key, _job} =
      Enum.find(state.running_jobs, {nil, nil}, fn {_key, value} ->
        value.ref == ref
      end)

    if is_nil(job_key) do
      {:noreply, state}
    else
      state =
        update_in(state.running_jobs, fn jobs ->
          Map.delete(jobs, job_key)
        end)

      case reason do
        :normal ->
          Logger.info("multi-project job completed key=#{job_key}")

        _ ->
          Logger.warning("multi-project job ended key=#{job_key} reason=#{inspect(reason)}")
      end

      {:noreply, state}
    end
  end

  def handle_info({:job_finished, job_key, result}, %State{} = state) do
    state =
      update_in(state.running_jobs, fn jobs ->
        Map.delete(jobs, job_key)
      end)

    case result do
      {:ok, summary} ->
        Logger.info("multi-project job finished key=#{job_key} summary=#{summary}")

      {:error, reason} ->
        Logger.error("multi-project job failed key=#{job_key} reason=#{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    projects =
      ProjectRegistry.list()
      |> Enum.map(fn project ->
        project_state = Map.get(state.project_states, project.id, %{})
        readiness = Project.readiness(project)

        %{
          project_id: project.id,
          project_name: project.name,
          provider: project.provider,
          mode: project.mode,
          enabled: project.enabled,
          ready: readiness.ready,
          missing_fields: readiness.missing_fields,
          tracked_issues: map_size(Map.get(project_state, :tracked_issues, %{})),
          running_jobs: running_job_count_for_project(state.running_jobs, project.id),
          last_poll_at: iso8601(Map.get(project_state, :last_poll_at)),
          last_error: Map.get(project_state, :last_error)
        }
      end)

    response = %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      counts: %{
        projects: length(projects),
        running_jobs: map_size(state.running_jobs)
      },
      projects: projects
    }

    {:reply, response, state}
  end

  def handle_call(:refresh, _from, %State{} = state) do
    send(self(), :run_poll_cycle)

    {:reply,
     %{
       queued: true,
       coalesced: false,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  @spec poll_projects(State.t()) :: State.t()
  defp poll_projects(%State{} = state) do
    projects = ProjectRegistry.list()

    Enum.reduce(projects, state, fn project, state_acc ->
      poll_project(project, state_acc)
    end)
  end

  @spec poll_project(Project.t(), State.t()) :: State.t()
  defp poll_project(%Project{} = project, %State{} = state) do
    readiness = Project.readiness(project)

    cond do
      not project.enabled ->
        state

      not readiness.ready ->
        put_project_state(state, project.id, %{last_error: "needs_input: #{Enum.join(readiness.missing_fields, ", ")}"})

      in_backoff?(state, project.id) ->
        state

      true ->
        do_poll_project(project, state)
    end
  end

  defp do_poll_project(%Project{} = project, %State{} = state) do
    case Tracker.Router.fetch_candidate_issues(project) do
      {:ok, issues} ->
        filtered_issues = filter_candidate_issues(issues, project)

        state =
          filtered_issues
          |> Enum.reduce(state, fn issue, state_acc ->
            maybe_start_job(project, issue, state_acc)
          end)

        state
        |> put_project_state(project.id, %{
          last_error: nil,
          next_poll_at_ms: nil,
          last_poll_at: DateTime.utc_now(),
          tracked_issues: track_issues(Map.get(state.project_states[project.id] || %{}, :tracked_issues, %{}), filtered_issues)
        })

      {:error, {:rate_limited, retry_after_ms}} ->
        ms = normalize_retry_ms(retry_after_ms)

        put_project_state(state, project.id, %{
          last_poll_at: DateTime.utc_now(),
          last_error: "rate_limited",
          next_poll_at_ms: System.monotonic_time(:millisecond) + ms
        })

      {:error, reason} ->
        put_project_state(state, project.id, %{
          last_poll_at: DateTime.utc_now(),
          last_error: inspect(reason),
          next_poll_at_ms: nil
        })
    end
  end

  @spec maybe_start_job(Project.t(), Issue.t(), State.t()) :: State.t()
  defp maybe_start_job(%Project{} = project, %Issue{} = issue, %State{} = state) do
    job_key = job_key(project.id, issue.id)
    project_state = Map.get(state.project_states, project.id, %{})
    tracked_issues = Map.get(project_state, :tracked_issues, %{})
    signature = issue_signature(issue)

    cond do
      Map.has_key?(state.running_jobs, job_key) ->
        state

      Map.get(tracked_issues, issue.id) == signature ->
        state

      true ->
        recipient = self()

        {:ok, pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            result = run_issue_job(project, issue)
            send(recipient, {:job_finished, job_key, result})
          end)

        ref = Process.monitor(pid)

        running_job = %{
          ref: ref,
          pid: pid,
          project_id: project.id,
          issue_id: issue.id,
          started_at: DateTime.utc_now(),
          issue_identifier: issue.identifier
        }

        put_in(state.running_jobs[job_key], running_job)
    end
  end

  @spec run_issue_job(Project.t(), Issue.t()) :: {:ok, String.t()} | {:error, term()}
  defp run_issue_job(%Project{} = project, %Issue{} = issue) do
    with {:ok, build_result} <- run_build(project),
         :ok <- post_result_comment(project, issue, build_result) do
      {:ok, build_result.summary}
    else
      {:error, reason} ->
        _ = post_failure_comment(project, issue, reason)
        {:error, reason}
    end
  end

  @spec run_build(Project.t()) :: {:ok, %{summary: String.t(), output: String.t()}} | {:error, term()}
  defp run_build(%Project{} = project) do
    commands = Map.get(project.build, "commands", [])
    timeout_ms = Map.get(project.build, "timeout_ms", 900_000)
    build_result(commands, build_working_dir(project), timeout_ms)
  end

  defp build_result([], _working_dir, _timeout_ms) do
    {:ok, %{summary: "no build commands configured", output: ""}}
  end

  defp build_result(commands, working_dir, timeout_ms) do
    case run_commands(commands, working_dir, timeout_ms) do
      {:ok, outputs} ->
        output = Enum.join(outputs, "\n\n")

        {:ok,
         %{
           summary: "build passed (#{length(commands)} commands)",
           output: truncate_output(output)
         }}

      {:error, {:command_failed, command, reason, outputs}} ->
        output = Enum.join(outputs, "\n\n")
        {:error, {:command_failed, command, reason, truncate_output(output)}}
    end
  end

  defp run_commands(commands, working_dir, timeout_ms) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, outputs} ->
      case run_command(command, working_dir, timeout_ms) do
        {:ok, output} -> {:cont, {:ok, outputs ++ ["$ #{command}\n#{output}"]}}
        {:error, reason} -> {:halt, {:error, {:command_failed, command, reason, outputs}}}
      end
    end)
  end

  @spec run_command(String.t(), String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp run_command(command, working_dir, timeout_ms) do
    {output, status} =
      System.cmd("bash", ["-lc", command],
        cd: working_dir,
        stderr_to_stdout: true,
        timeout: timeout_ms
      )

    if status == 0 do
      {:ok, output}
    else
      {:error, {:exit_status, status, truncate_output(output)}}
    end
  rescue
    error -> {:error, {:command_error, error}}
  end

  @spec post_result_comment(
          Project.t(),
          Issue.t(),
          %{summary: String.t(), output: String.t()}
        ) :: :ok | {:error, term()}
  defp post_result_comment(project, issue, build_result) do
    mode_line = if project.mode == "full_agent", do: "full_agent", else: "build_only"

    body =
      [
        "## Symphony Build Result",
        "",
        "- Project: `#{project.name}`",
        "- Mode: `#{mode_line}`",
        "- Result: #{build_result.summary}",
        "",
        "```text",
        build_result.output,
        "```"
      ]
      |> Enum.join("\n")

    Tracker.Router.create_comment(project, issue.id, body)
  end

  @spec post_failure_comment(Project.t(), Issue.t(), term()) :: :ok | {:error, term()}
  defp post_failure_comment(project, issue, reason) do
    body =
      [
        "## Symphony Build Failed",
        "",
        "- Project: `#{project.name}`",
        "- Mode: `#{project.mode}`",
        "- Error: `#{inspect(reason)}`"
      ]
      |> Enum.join("\n")

    Tracker.Router.create_comment(project, issue.id, body)
  end

  @spec filter_candidate_issues([Issue.t()], Project.t()) :: [Issue.t()]
  defp filter_candidate_issues(issues, %Project{} = project) do
    active_states = project |> Project.active_states() |> Enum.map(&normalize_state/1) |> MapSet.new()
    labels_include = MapSet.new(Project.labels_include(project))
    labels_exclude = MapSet.new(Project.labels_exclude(project))

    Enum.filter(issues, fn
      %Issue{} = issue ->
        state_ok = MapSet.member?(active_states, normalize_state(issue.state))
        labels = MapSet.new(Enum.map(issue.labels, &String.downcase/1))

        include_ok =
          case MapSet.size(labels_include) do
            0 -> true
            _ -> not MapSet.disjoint?(labels, labels_include)
          end

        exclude_ok =
          case MapSet.size(labels_exclude) do
            0 -> true
            _ -> MapSet.disjoint?(labels, labels_exclude)
          end

        state_ok and include_ok and exclude_ok

      _ ->
        false
    end)
  end

  @spec track_issues(map(), [Issue.t()]) :: map()
  defp track_issues(existing, issues) when is_map(existing) do
    Enum.reduce(issues, existing, fn issue, acc ->
      Map.put(acc, issue.id, issue_signature(issue))
    end)
  end

  @spec issue_signature(Issue.t()) :: String.t()
  defp issue_signature(%Issue{} = issue) do
    updated = iso8601(issue.updated_at) || ""
    updated <> "|" <> normalize_state(issue.state)
  end

  @spec put_project_state(State.t(), String.t(), map()) :: State.t()
  defp put_project_state(%State{} = state, project_id, attrs) do
    current = Map.get(state.project_states, project_id, %{})
    updated = Map.merge(current, attrs)
    %{state | project_states: Map.put(state.project_states, project_id, updated)}
  end

  @spec in_backoff?(State.t(), String.t()) :: boolean()
  defp in_backoff?(%State{} = state, project_id) do
    next_poll_at_ms =
      state.project_states
      |> Map.get(project_id, %{})
      |> Map.get(:next_poll_at_ms)

    is_integer(next_poll_at_ms) and next_poll_at_ms > System.monotonic_time(:millisecond)
  end

  @spec running_job_count_for_project(map(), String.t()) :: non_neg_integer()
  defp running_job_count_for_project(running_jobs, project_id) do
    Enum.count(running_jobs, fn {_job_key, job} -> job.project_id == project_id end)
  end

  @spec build_working_dir(Project.t()) :: String.t()
  defp build_working_dir(%Project{} = project) do
    case Map.get(project.build, "workdir") do
      nil -> project.repo_path
      relative -> Path.expand(Path.join(project.repo_path, relative))
    end
  end

  @spec normalize_retry_ms(term()) :: non_neg_integer()
  defp normalize_retry_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_retry_ms(_value), do: @default_retry_after_ms

  @spec truncate_output(String.t()) :: String.t()
  defp truncate_output(output) when is_binary(output) do
    if byte_size(output) > @max_output_bytes do
      binary_part(output, 0, @max_output_bytes) <> "\n...<truncated>"
    else
      output
    end
  end

  @spec normalize_state(String.t() | nil) :: String.t()
  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_), do: ""

  @spec job_key(String.t(), String.t()) :: job_key()
  defp job_key(project_id, issue_id), do: project_id <> ":" <> issue_id

  @spec schedule_tick(non_neg_integer()) :: :ok
  defp schedule_tick(delay_ms) do
    Process.send_after(self(), :tick, max(delay_ms, 0))
    :ok
  end

  @spec iso8601(DateTime.t() | nil) :: String.t() | nil
  defp iso8601(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_), do: nil
end
