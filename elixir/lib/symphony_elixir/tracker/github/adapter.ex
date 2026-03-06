defmodule SymphonyElixir.Tracker.GitHub.Adapter do
  @moduledoc """
  GitHub adapter wrapper for project-scoped tracker operations.
  """

  alias SymphonyElixir.Project
  alias SymphonyElixir.Tracker.GitHub.Client

  @spec fetch_candidate_issues(Project.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(%Project{} = project), do: Client.fetch_candidate_issues(project)

  @spec fetch_issue_states_by_ids(Project.t(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(%Project{} = project, issue_ids), do: Client.fetch_issue_states_by_ids(project, issue_ids)

  @spec create_comment(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Project{} = project, issue_id, body), do: Client.create_comment(project, issue_id, body)

  @spec replace_labels(Project.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def replace_labels(%Project{} = project, issue_id, labels), do: Client.replace_labels(project, issue_id, labels)

  @spec update_issue_state(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Project{} = project, issue_id, state_name),
    do: Client.update_issue_state(project, issue_id, state_name)
end
