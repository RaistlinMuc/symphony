defmodule SymphonyElixir.MultiProjectAgentRunner do
  @moduledoc """
  Executes a multi-project full-agent run in an isolated workspace clone.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{MultiProjectPromptBuilder, MultiProjectWorkspace, Project}
  alias SymphonyElixir.Tracker.Issue

  @spec run(Project.t(), Issue.t(), keyword()) ::
          {:ok, %{summary: String.t(), comment_body: String.t(), workspace: String.t()}} | {:error, term()}
  def run(%Project{} = project, %Issue{} = issue, opts \\ []) do
    app_server_module = Keyword.get(opts, :app_server_module, AppServer)
    app_server_opts = Keyword.get(opts, :app_server_opts, [])
    workspace_opts = Keyword.get(opts, :workspace_opts, [])

    with {:ok, workspace} <- MultiProjectWorkspace.create_for_issue(project, issue, workspace_opts),
         prompt <- build_prompt(project, issue, workspace),
         {:ok, _result} <-
           app_server_module.run(
             workspace.path,
             prompt,
             issue,
             Keyword.merge(app_server_opts, issue_comment_path: workspace.comment_file)
           ),
         {:ok, comment_body} <- read_issue_comment(workspace.comment_file) do
      {:ok,
       %{
         summary: summarize_comment(comment_body),
         comment_body: comment_body,
         workspace: workspace.path
       }}
    else
      {:error, reason} ->
        Logger.error("full-agent run failed project_id=#{project.id} issue_id=#{issue.id} reason=#{inspect(reason)}")

        {:error, reason}
    end
  end

  @spec build_prompt(Project.t(), Issue.t(), MultiProjectWorkspace.workspace_info()) :: String.t()
  defp build_prompt(%Project{} = project, %Issue{} = issue, workspace) do
    MultiProjectPromptBuilder.build_prompt(project, issue, workspace.path, comment_file: workspace.comment_file)
  end

  @spec read_issue_comment(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_issue_comment(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        trimmed = String.trim(body)

        if trimmed == "" do
          {:error, :missing_agent_issue_comment}
        else
          {:ok, trimmed}
        end

      {:error, reason} ->
        {:error, {:missing_agent_issue_comment, reason}}
    end
  end

  @spec summarize_comment(String.t()) :: String.t()
  defp summarize_comment(comment_body) do
    comment_body
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "agent completed"
      line -> String.slice(line, 0, 120)
    end
  end
end
