defmodule SymphonyElixirWeb.ProjectsApiController do
  @moduledoc """
  JSON API for discovered and monitored project management.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Project, ProjectDiscovery, ProjectRegistry}

  @spec discovered(Conn.t(), map()) :: Conn.t()
  def discovered(conn, _params) do
    json(conn, %{projects: ProjectDiscovery.list()})
  end

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    projects =
      ProjectRegistry.list()
      |> Enum.map(&project_payload/1)

    json(conn, %{projects: projects})
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    case ProjectRegistry.create(params) do
      {:ok, project} ->
        conn
        |> put_status(201)
        |> json(project_payload(project))

      {:error, reason} ->
        error_response(conn, 422, "project_create_failed", inspect(reason))
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"id" => project_id} = params) do
    attrs = Map.delete(params, "id")

    case ProjectRegistry.update(project_id, attrs) do
      {:ok, project} ->
        json(conn, project_payload(project))

      {:error, :not_found} ->
        error_response(conn, 404, "project_not_found", "Project not found")

      {:error, reason} ->
        error_response(conn, 422, "project_update_failed", inspect(reason))
    end
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, %{"id" => project_id}) do
    case ProjectRegistry.delete(project_id) do
      :ok ->
        conn
        |> put_status(204)
        |> text("")

      {:error, :not_found} ->
        error_response(conn, 404, "project_not_found", "Project not found")
    end
  end

  @spec enable(Conn.t(), map()) :: Conn.t()
  def enable(conn, %{"id" => project_id}) do
    case ProjectRegistry.enable(project_id) do
      {:ok, project} -> json(conn, project_payload(project))
      {:error, :not_found} -> error_response(conn, 404, "project_not_found", "Project not found")
      {:error, reason} -> error_response(conn, 422, "project_enable_failed", inspect(reason))
    end
  end

  @spec disable(Conn.t(), map()) :: Conn.t()
  def disable(conn, %{"id" => project_id}) do
    case ProjectRegistry.disable(project_id) do
      {:ok, project} -> json(conn, project_payload(project))
      {:error, :not_found} -> error_response(conn, 404, "project_not_found", "Project not found")
      {:error, reason} -> error_response(conn, 422, "project_disable_failed", inspect(reason))
    end
  end

  @spec readiness(Conn.t(), map()) :: Conn.t()
  def readiness(conn, %{"id" => project_id}) do
    case ProjectRegistry.readiness(project_id) do
      {:ok, result} -> json(conn, result)
      {:error, :not_found} -> error_response(conn, 404, "project_not_found", "Project not found")
    end
  end

  @spec status(Conn.t(), map()) :: Conn.t()
  def status(conn, _params) do
    payload =
      case SymphonyElixir.MultiProjectOrchestrator.snapshot() do
        :timeout -> %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}
        :unavailable -> %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
        snapshot -> snapshot
      end

    json(conn, payload)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp project_payload(%Project{} = project) do
    readiness = Project.readiness(project)

    %{
      id: project.id,
      name: project.name,
      repo_path: project.repo_path,
      enabled: project.enabled,
      mode: project.mode,
      provider: project.provider,
      provider_config: project.provider_config,
      build: project.build,
      ticket_mapping: project.ticket_mapping,
      created_at: project.created_at,
      updated_at: project.updated_at,
      last_changed_at: project.last_changed_at,
      readiness: readiness
    }
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
