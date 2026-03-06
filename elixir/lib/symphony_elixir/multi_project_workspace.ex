defmodule SymphonyElixir.MultiProjectWorkspace do
  @moduledoc """
  Creates isolated workspaces for multi-project full-agent runs.
  """

  require Logger

  alias SymphonyElixir.{Config, Project}
  alias SymphonyElixir.Tracker.Issue

  @comment_rel_path ".symphony/issue_comment.md"

  @type workspace_info :: %{
          path: String.t(),
          comment_file: String.t(),
          clone_source: String.t()
        }

  @spec create_for_issue(Project.t(), Issue.t(), keyword()) :: {:ok, workspace_info()} | {:error, term()}
  def create_for_issue(%Project{} = project, %Issue{} = issue, opts \\ []) do
    workspace = workspace_path(project, issue)

    with :ok <- validate_workspace_path(workspace),
         :ok <- reset_workspace(workspace),
         {:ok, clone_source, origin_url} <- clone_details(project, opts),
         :ok <- clone_repo(clone_source, origin_url, workspace),
         :ok <- copy_git_identity(project.repo_path, workspace),
         :ok <- initialize_workspace_files(workspace) do
      {:ok,
       %{
         path: workspace,
         comment_file: Path.join(workspace, @comment_rel_path),
         clone_source: clone_source
       }}
    end
  end

  @spec workspace_path(Project.t(), Issue.t()) :: String.t()
  def workspace_path(%Project{} = project, %Issue{} = issue) do
    Path.join([
      Config.workspace_root(),
      "projects",
      safe_segment(project.name || project.id),
      safe_segment(issue.identifier || issue.id)
    ])
  end

  @spec issue_comment_rel_path() :: String.t()
  def issue_comment_rel_path, do: @comment_rel_path

  @spec clone_details(Project.t(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, term()}
  defp clone_details(%Project{} = project, opts) do
    clone_source =
      Keyword.get(opts, :clone_source) ||
        target_remote_url(project) ||
        project.repo_path

    origin_url =
      Keyword.get(opts, :origin_url) ||
        target_remote_url(project)

    if not is_binary(clone_source) or String.trim(clone_source) == "" do
      {:error, :missing_clone_source}
    else
      {:ok, clone_source, origin_url}
    end
  end

  @spec clone_repo(String.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  defp clone_repo(clone_source, origin_url, workspace) do
    case System.cmd("git", ["clone", clone_source, workspace], stderr_to_stdout: true) do
      {_output, 0} ->
        maybe_set_origin_url(workspace, clone_source, origin_url)

      {output, status} ->
        {:error, {:workspace_clone_failed, status, output}}
    end
  rescue
    error -> {:error, {:workspace_clone_error, error}}
  end

  @spec maybe_set_origin_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  defp maybe_set_origin_url(_workspace, _clone_source, nil), do: :ok

  defp maybe_set_origin_url(workspace, clone_source, origin_url) do
    if clone_source == origin_url do
      :ok
    else
      case System.cmd("git", ["-C", workspace, "remote", "set-url", "origin", origin_url], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:workspace_origin_set_failed, status, output}}
      end
    end
  rescue
    error -> {:error, {:workspace_origin_set_error, error}}
  end

  @spec copy_git_identity(String.t(), String.t()) :: :ok
  defp copy_git_identity(source_repo, workspace) do
    Enum.each(["user.name", "user.email"], fn key ->
      case read_git_config(source_repo, key) do
        {:ok, value} ->
          _ = System.cmd("git", ["-C", workspace, "config", key, value], stderr_to_stdout: true)
          :ok

        _ ->
          :ok
      end
    end)

    :ok
  end

  @spec read_git_config(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp read_git_config(repo_path, key) do
    case System.cmd("git", ["-C", repo_path, "config", key], stderr_to_stdout: true) do
      {value, 0} ->
        trimmed = String.trim(value)
        if trimmed == "", do: :error, else: {:ok, trimmed}

      _ ->
        :error
    end
  rescue
    _error ->
      :error
  end

  @spec initialize_workspace_files(String.t()) :: :ok | {:error, term()}
  defp initialize_workspace_files(workspace) do
    comment_file = Path.join(workspace, @comment_rel_path)

    comment_file
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(comment_file, "")
    :ok
  rescue
    error -> {:error, {:workspace_init_failed, error}}
  end

  @spec target_remote_url(Project.t()) :: String.t() | nil
  defp target_remote_url(%Project{} = project) do
    case matching_remote_url(project) do
      {:ok, url} ->
        url

      :error ->
        fallback_remote_url(project)
    end
  end

  @spec matching_remote_url(Project.t()) :: {:ok, String.t()} | :error
  defp matching_remote_url(%Project{} = project) do
    project.repo_path
    |> list_remote_urls()
    |> Enum.find(&remote_matches_project?(&1, project))
    |> case do
      nil -> :error
      url -> {:ok, url}
    end
  end

  @spec list_remote_urls(String.t()) :: [String.t()]
  defp list_remote_urls(repo_path) do
    case System.cmd("git", ["-C", repo_path, "config", "--get-regexp", "^remote\\..*\\.url$"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_remote_url_line/1)

      _ ->
        []
    end
  rescue
    _error ->
      []
  end

  @spec parse_remote_url_line(String.t()) :: [String.t()]
  defp parse_remote_url_line(line) do
    case String.split(line, " ", parts: 2) do
      [_key, url] -> [String.trim(url)]
      _ -> []
    end
  end

  @spec remote_matches_project?(String.t(), Project.t()) :: boolean()
  defp remote_matches_project?(url, %Project{provider: "github", provider_config: provider_config}) do
    owner = Regex.escape(provider_config["owner"] || "")
    repo = Regex.escape(provider_config["repo"] || "")

    owner != "" and repo != "" and
      Regex.match?(~r/github\.com[:\/]#{owner}\/#{repo}(\.git)?$/i, url)
  end

  defp remote_matches_project?(url, %Project{provider: "gitlab", provider_config: provider_config}) do
    host = provider_config["base_url"] |> to_host() |> Regex.escape()
    project_path = Regex.escape(provider_config["project_path"] || "")

    host != "" and project_path != "" and
      Regex.match?(~r/#{host}[:\/]#{project_path}(\.git)?$/i, url)
  end

  defp remote_matches_project?(_url, _project), do: false

  @spec fallback_remote_url(Project.t()) :: String.t() | nil
  defp fallback_remote_url(%Project{provider: "github", provider_config: provider_config}) do
    owner = provider_config["owner"]
    repo = provider_config["repo"]

    if blank?(owner) or blank?(repo) do
      nil
    else
      "git@github.com:#{owner}/#{repo}.git"
    end
  end

  defp fallback_remote_url(%Project{provider: "gitlab", provider_config: provider_config}) do
    host = to_host(provider_config["base_url"])
    project_path = provider_config["project_path"]

    if blank?(host) or blank?(project_path) do
      nil
    else
      "git@#{host}:#{project_path}.git"
    end
  end

  defp fallback_remote_url(_project), do: nil

  @spec to_host(String.t() | nil) :: String.t() | nil
  defp to_host(nil), do: nil

  defp to_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  @spec validate_workspace_path(String.t()) :: :ok | {:error, term()}
  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root <> "/") ->
        :ok

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  @spec reset_workspace(String.t()) :: :ok
  defp reset_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.dirname(workspace))
    :ok
  end

  @spec safe_segment(String.t() | nil) :: String.t()
  defp safe_segment(value) do
    value
    |> Kernel.||("item")
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.trim("_")
    |> case do
      "" -> "item"
      safe -> safe
    end
  end

  @spec blank?(term()) :: boolean()
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
