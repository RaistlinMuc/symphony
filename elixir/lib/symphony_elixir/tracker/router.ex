defmodule SymphonyElixir.Tracker.Router do
  @moduledoc """
  Project-aware tracker router for GitHub/GitLab adapters.
  """

  alias SymphonyElixir.Project
  alias SymphonyElixir.Tracker.{GitHub, GitLab}

  @spec fetch_candidate_issues(Project.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(%Project{} = project) do
    adapter(project).fetch_candidate_issues(project)
  end

  @spec fetch_issue_states_by_ids(Project.t(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(%Project{} = project, issue_ids) do
    adapter(project).fetch_issue_states_by_ids(project, issue_ids)
  end

  @spec create_comment(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Project{} = project, issue_id, body) do
    adapter(project).create_comment(project, issue_id, body)
  end

  @spec replace_labels(Project.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def replace_labels(%Project{} = project, issue_id, labels) when is_list(labels) do
    adapter(project).replace_labels(project, issue_id, labels)
  end

  @spec update_issue_state(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Project{} = project, issue_id, state_name) do
    adapter(project).update_issue_state(project, issue_id, state_name)
  end

  @spec adapter(Project.t()) :: module()
  defp adapter(%Project{provider: "github"}), do: GitHub.Adapter
  defp adapter(%Project{provider: "gitlab"}), do: GitLab.Adapter
  defp adapter(_project), do: GitHub.Adapter
end
