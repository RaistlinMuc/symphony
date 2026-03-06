defmodule SymphonyElixir.MultiProjectPromptBuilder do
  @moduledoc """
  Builds provider-neutral prompts for multi-project full-agent runs.
  """

  alias SymphonyElixir.Project
  alias SymphonyElixir.Tracker.Issue

  @spec build_prompt(Project.t(), Issue.t(), String.t(), keyword()) :: String.t()
  def build_prompt(%Project{} = project, %Issue{} = issue, workspace, opts \\ [])
      when is_binary(workspace) do
    comment_file =
      opts
      |> Keyword.get(:comment_file, Path.join(workspace, ".symphony/issue_comment.md"))
      |> Path.expand()

    """
    You are Symphony operating in full_agent mode for a tracked #{provider_label(project)} item.

    Repository: #{repository_label(project)}
    Provider: #{project.provider}
    Issue: #{issue.identifier} - #{issue.title}
    URL: #{issue.url || "n/a"}
    Labels: #{format_labels(issue.labels)}
    Workspace: #{Path.expand(workspace)}
    Comment file: #{comment_file}

    Issue description:
    #{issue.description || "No description provided."}

    Instructions:
    1. Work only inside this cloned repository workspace.
    2. Complete the task described by the issue body. If the task can be completed by posting a comment only, avoid unnecessary code changes.
    3. Do not post issue comments directly through #{provider_label(project)}. Symphony will post exactly the contents of `#{comment_file}` after your run.
    4. Before ending your turn, write the exact markdown issue comment for Symphony to post into `#{comment_file}`.
    5. Keep the comment file ready to post as-is. If you created code changes, include branch, commit, validation, and PR/MR URL in that comment.
    6. If you are blocked, explain the blocker in the comment file instead of asking a human follow-up question.
    7. You may use shell tools, git, and repository-local tooling available in the workspace.
    #{provider_specific_instructions(project)}
    """
    |> String.trim()
  end

  @spec repository_label(Project.t()) :: String.t()
  defp repository_label(%Project{provider: "github", provider_config: provider_config}) do
    "#{provider_config["owner"]}/#{provider_config["repo"]}"
  end

  defp repository_label(%Project{provider: "gitlab", provider_config: provider_config}) do
    provider_config["project_path"] || provider_config["project_id"] || "gitlab-project"
  end

  defp repository_label(%Project{name: name}), do: name

  @spec provider_label(Project.t()) :: String.t()
  defp provider_label(%Project{provider: "github"}), do: "GitHub"
  defp provider_label(%Project{provider: "gitlab"}), do: "GitLab"
  defp provider_label(_project), do: "tracker"

  @spec provider_specific_instructions(Project.t()) :: String.t()
  defp provider_specific_instructions(%Project{provider: "github", provider_config: provider_config}) do
    """
    GitHub notes:
    - `gh` CLI is available and authenticated for `#{provider_config["owner"]}/#{provider_config["repo"]}`.
    - `origin` points at the tracked repository so normal branch/push/PR flows can use git and `gh`.
    - Do not use `gh issue comment`; write the desired issue reply into the comment file instead.
    """
    |> String.trim()
  end

  defp provider_specific_instructions(%Project{provider: "gitlab", provider_config: provider_config}) do
    """
    GitLab notes:
    - `origin` points at the tracked GitLab repository#{gitlab_host_suffix(provider_config)}.
    - Do not post issue comments directly; write the desired issue reply into the comment file instead.
    """
    |> String.trim()
  end

  defp provider_specific_instructions(_project), do: ""

  @spec gitlab_host_suffix(map()) :: String.t()
  defp gitlab_host_suffix(provider_config) do
    case provider_config["base_url"] do
      nil -> ""
      base_url -> " on #{base_url}"
    end
  end

  @spec format_labels([String.t()]) :: String.t()
  defp format_labels([]), do: "(none)"
  defp format_labels(labels), do: Enum.join(labels, ", ")
end
