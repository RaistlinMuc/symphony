defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  Persistent CRUD registry for monitored projects.
  """

  use GenServer

  alias SymphonyElixir.Project

  @registry_version 1

  defmodule State do
    @moduledoc false
    defstruct [:path, projects: []]
  end

  @type project_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list(GenServer.name()) :: [Project.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec get(project_id(), GenServer.name()) :: {:ok, Project.t()} | {:error, :not_found}
  def get(project_id, server \\ __MODULE__) when is_binary(project_id) do
    GenServer.call(server, {:get, project_id})
  end

  @spec create(map(), GenServer.name()) :: {:ok, Project.t()} | {:error, term()}
  def create(attrs, server \\ __MODULE__) when is_map(attrs) do
    GenServer.call(server, {:create, attrs})
  end

  @spec update(project_id(), map(), GenServer.name()) :: {:ok, Project.t()} | {:error, term()}
  def update(project_id, attrs, server \\ __MODULE__) when is_binary(project_id) and is_map(attrs) do
    GenServer.call(server, {:update, project_id, attrs})
  end

  @spec delete(project_id(), GenServer.name()) :: :ok | {:error, :not_found}
  def delete(project_id, server \\ __MODULE__) when is_binary(project_id) do
    GenServer.call(server, {:delete, project_id})
  end

  @spec enable(project_id(), GenServer.name()) :: {:ok, Project.t()} | {:error, term()}
  def enable(project_id, server \\ __MODULE__) when is_binary(project_id) do
    update(project_id, %{"enabled" => true}, server)
  end

  @spec disable(project_id(), GenServer.name()) :: {:ok, Project.t()} | {:error, term()}
  def disable(project_id, server \\ __MODULE__) when is_binary(project_id) do
    update(project_id, %{"enabled" => false}, server)
  end

  @spec readiness(project_id(), GenServer.name()) :: {:ok, map()} | {:error, :not_found}
  def readiness(project_id, server \\ __MODULE__) when is_binary(project_id) do
    case get(project_id, server) do
      {:ok, project} -> {:ok, Project.readiness(project)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec storage_path() :: String.t()
  def storage_path do
    Application.get_env(:symphony_elixir, :projects_registry_path) ||
      Path.join([System.user_home!(), ".codex", "symphony", "projects.json"])
  end

  @impl true
  def init(_opts) do
    path = storage_path()

    projects =
      case read_projects(path) do
        {:ok, projects} -> projects
        {:error, _reason} -> []
      end

    {:ok, %State{path: path, projects: projects}}
  end

  @impl true
  def handle_call(:list, _from, %State{projects: projects} = state) do
    {:reply, projects, state}
  end

  def handle_call({:get, project_id}, _from, %State{projects: projects} = state) do
    case Enum.find(projects, &(&1.id == project_id)) do
      nil -> {:reply, {:error, :not_found}, state}
      project -> {:reply, {:ok, project}, state}
    end
  end

  def handle_call({:create, attrs}, _from, %State{} = state) do
    with {:ok, project} <- Project.new(attrs),
         :ok <- ensure_unique_name_and_path(project, state.projects),
         updated_projects <- sort_projects([project | state.projects]),
         :ok <- write_projects(state.path, updated_projects) do
      {:reply, {:ok, project}, %{state | projects: updated_projects}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, project_id, attrs}, _from, %State{} = state) do
    with {:ok, existing} <- find_project(state.projects, project_id),
         {:ok, updated} <- Project.update(existing, attrs),
         :ok <- ensure_unique_name_and_path(updated, state.projects, except_id: project_id),
         updated_projects <-
           state.projects
           |> Enum.map(fn
             %Project{id: ^project_id} -> updated
             project -> project
           end)
           |> sort_projects(),
         :ok <- write_projects(state.path, updated_projects) do
      {:reply, {:ok, updated}, %{state | projects: updated_projects}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, project_id}, _from, %State{} = state) do
    case Enum.any?(state.projects, &(&1.id == project_id)) do
      false ->
        {:reply, {:error, :not_found}, state}

      true ->
        updated_projects = Enum.reject(state.projects, &(&1.id == project_id))

        case write_projects(state.path, updated_projects) do
          :ok -> {:reply, :ok, %{state | projects: updated_projects}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @spec read_projects(String.t()) :: {:ok, [Project.t()]} | {:error, term()}
  defp read_projects(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_projects(content)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decode_projects(String.t()) :: {:ok, [Project.t()]} | {:error, term()}
  defp decode_projects(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         {:ok, projects} <- map_projects(payload) do
      {:ok, sort_projects(projects)}
    end
  end

  @spec map_projects(map()) :: {:ok, [Project.t()]} | {:error, term()}
  defp map_projects(%{"projects" => projects}) when is_list(projects) do
    projects
    |> Enum.reduce_while({:ok, []}, fn project_map, {:ok, acc} ->
      case Project.from_map(project_map) do
        {:ok, project} -> {:cont, {:ok, [project | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_project, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_projects(_), do: {:ok, []}

  @spec write_projects(String.t(), [Project.t()]) :: :ok | {:error, term()}
  defp write_projects(path, projects) when is_binary(path) and is_list(projects) do
    payload = %{
      "version" => @registry_version,
      "projects" => Enum.map(projects, &Project.to_map/1)
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(payload, pretty: true),
         :ok <- File.write(path, json <> "\n") do
      :ok
    end
  end

  @spec ensure_unique_name_and_path(Project.t(), [Project.t()], keyword()) :: :ok | {:error, term()}
  defp ensure_unique_name_and_path(%Project{} = project, projects, opts \\ []) do
    except_id = Keyword.get(opts, :except_id)

    filtered =
      Enum.reject(projects, fn
        %Project{id: ^except_id} -> true
        _ -> false
      end)

    duplicate_name = Enum.find(filtered, &(&1.name == project.name))
    duplicate_path = Enum.find(filtered, &(Path.expand(&1.repo_path) == Path.expand(project.repo_path)))

    cond do
      duplicate_name -> {:error, :duplicate_project_name}
      duplicate_path -> {:error, :duplicate_repo_path}
      true -> :ok
    end
  end

  @spec find_project([Project.t()], project_id()) :: {:ok, Project.t()} | {:error, :not_found}
  defp find_project(projects, project_id) do
    case Enum.find(projects, &(&1.id == project_id)) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @spec sort_projects([Project.t()]) :: [Project.t()]
  defp sort_projects(projects) do
    Enum.sort_by(
      projects,
      fn project ->
        last_changed = project.last_changed_at || ""
        {last_changed, project.updated_at, project.name}
      end,
      :desc
    )
  end
end
