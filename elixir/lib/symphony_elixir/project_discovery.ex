defmodule SymphonyElixir.ProjectDiscovery do
  @moduledoc """
  Discovers candidate projects from Codex global state.
  """

  @codex_global_state_path Path.join([System.user_home!(), ".codex", ".codex-global-state.json"])

  @type discovered_project :: %{
          path: String.t(),
          name: String.t(),
          is_active: boolean(),
          git: %{
            root: String.t(),
            remote_urls: [String.t()],
            branch: String.t() | nil,
            last_changed_at: String.t() | nil
          }
        }

  @spec list() :: [discovered_project()]
  def list do
    with {:ok, state} <- read_state_file(),
         saved_roots <- normalize_paths(Map.get(state, "electron-saved-workspace-roots", [])),
         active_roots <- MapSet.new(normalize_paths(Map.get(state, "active-workspace-roots", []))) do
      saved_roots
      |> Enum.uniq()
      |> Enum.map(&build_entry(&1, active_roots))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&sort_key/1, :desc)
    else
      _ -> []
    end
  end

  @spec state_path() :: String.t()
  def state_path do
    Application.get_env(:symphony_elixir, :codex_global_state_path, @codex_global_state_path)
  end

  @spec read_state_file() :: {:ok, map()} | {:error, term()}
  defp read_state_file do
    with {:ok, content} <- File.read(state_path()),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_codex_state}
    end
  end

  @spec normalize_paths(term()) :: [String.t()]
  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(fn
      path when is_binary(path) -> String.trim(path)
      _ -> nil
    end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
  end

  defp normalize_paths(_), do: []

  @spec build_entry(String.t(), MapSet.t(String.t())) :: discovered_project() | nil
  defp build_entry(path, active_roots) when is_binary(path) do
    case git_info(path) do
      {:ok, git} ->
        %{
          path: path,
          name: Path.basename(path),
          is_active: MapSet.member?(active_roots, path),
          git: git
        }

      {:error, _reason} ->
        nil
    end
  end

  @spec git_info(String.t()) :: {:ok, map()} | {:error, term()}
  defp git_info(path) do
    with :ok <- ensure_git_repo(path),
         {:ok, root} <- run_git(path, ["rev-parse", "--show-toplevel"]),
         {:ok, branch} <- run_git(path, ["rev-parse", "--abbrev-ref", "HEAD"], allow_error: true),
         {:ok, remotes} <- run_git(path, ["remote", "-v"], allow_error: true),
         {:ok, last_changed_at} <- resolve_last_changed_at(path) do
      {:ok,
       %{
         root: root,
         remote_urls: parse_remote_urls(remotes),
         branch: blank_to_nil(branch),
         last_changed_at: last_changed_at
       }}
    end
  end

  @spec ensure_git_repo(String.t()) :: :ok | {:error, term()}
  defp ensure_git_repo(path) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: path, stderr_to_stdout: true) do
      {"true\n", 0} -> :ok
      {_output, _code} -> {:error, :not_git_repo}
    end
  rescue
    _error -> {:error, :not_git_repo}
  end

  @spec resolve_last_changed_at(String.t()) :: {:ok, String.t() | nil}
  defp resolve_last_changed_at(path) do
    case run_git(path, ["log", "-1", "--format=%ct"], allow_error: true) do
      {:ok, value} when is_binary(value) and value != "" ->
        case Integer.parse(String.trim(value)) do
          {unix, _} ->
            {:ok, DateTime.from_unix!(unix) |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

          _ ->
            {:ok, dir_mtime(path)}
        end

      _ ->
        {:ok, dir_mtime(path)}
    end
  end

  @spec dir_mtime(String.t()) :: String.t() | nil
  defp dir_mtime(path) do
    with {:ok, stat} <- File.stat(path),
         %NaiveDateTime{} = mtime <- stat.mtime,
         {:ok, dt} <- DateTime.from_naive(mtime, "Etc/UTC") do
      DateTime.to_iso8601(DateTime.truncate(dt, :second))
    else
      _ -> nil
    end
  end

  @spec run_git(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  defp run_git(path, args, opts \\ []) do
    allow_error = Keyword.get(opts, :allow_error, false)

    try do
      case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {_, _} when allow_error -> {:ok, ""}
        {output, code} -> {:error, {:git_failed, args, code, output}}
      end
    rescue
      _error ->
        if allow_error, do: {:ok, ""}, else: {:error, :git_unavailable}
    end
  end

  @spec parse_remote_urls(String.t()) :: [String.t()]
  defp parse_remote_urls(remotes) do
    remotes
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ~r/\s+/, trim: true))
    |> Enum.filter(&(length(&1) >= 2))
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
  end

  @spec sort_key(discovered_project()) :: {integer(), integer(), String.t()}
  defp sort_key(project) do
    last_changed = project.git.last_changed_at || ""
    active = if project.is_active, do: 1, else: 0
    {active, iso_to_unix(last_changed), project.name}
  end

  @spec iso_to_unix(String.t()) :: integer()
  defp iso_to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil
end
