defmodule SymphonyElixir.MultiProjectAgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    MultiProjectAgentRunner,
    MultiProjectPromptBuilder,
    MultiProjectWorkspace,
    Project
  }

  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    def run(workspace, prompt, issue, opts) do
      send(opts[:test_pid], {:fake_app_server_run, workspace, prompt, issue, opts})
      File.write!(opts[:issue_comment_path], "Agent says hi from #{issue.identifier}")
      {:ok, %{result: :completed}}
    end
  end

  test "full agent runner clones the repo and returns the generated issue comment" do
    {repo_path, workspace_root} = create_repo_fixture("runner")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    {:ok, project} =
      Project.new(%{
        "name" => "RunnerProject",
        "repo_path" => repo_path,
        "provider" => "github",
        "mode" => "full_agent",
        "provider_config" => %{
          "owner" => "RaistlinMuc",
          "repo" => "symphony"
        }
      })

    issue = issue_fixture(identifier: "#77", title: "Tell a joke", description: "Comment with a joke")

    assert {:ok, result} =
             MultiProjectAgentRunner.run(project, issue,
               app_server_module: FakeAppServer,
               app_server_opts: [test_pid: self()],
               workspace_opts: [clone_source: repo_path, origin_url: "git@github.com:RaistlinMuc/symphony.git"]
             )

    assert result.comment_body == "Agent says hi from #77"
    assert result.summary == "Agent says hi from #77"
    assert File.exists?(Path.join(result.workspace, ".git"))
    assert File.read!(Path.join(result.workspace, "README.md")) =~ "fixture runner"

    assert_received {:fake_app_server_run, workspace, prompt, ^issue, opts}
    assert workspace == result.workspace
    assert opts[:issue_comment_path] == Path.join(result.workspace, ".symphony/issue_comment.md")
    assert prompt =~ "Comment file:"
    assert prompt =~ "Do not post issue comments directly"
    assert prompt =~ "Tell a joke"
  end

  test "workspace clone resets origin to the tracked remote url" do
    {repo_path, workspace_root} = create_repo_fixture("workspace")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    {:ok, project} =
      Project.new(%{
        "name" => "WorkspaceProject",
        "repo_path" => repo_path,
        "provider" => "github",
        "mode" => "full_agent",
        "provider_config" => %{
          "owner" => "RaistlinMuc",
          "repo" => "symphony"
        }
      })

    issue = issue_fixture(identifier: "#88")

    assert {:ok, workspace} =
             MultiProjectWorkspace.create_for_issue(project, issue,
               clone_source: repo_path,
               origin_url: "git@github.com:RaistlinMuc/symphony.git"
             )

    assert workspace.comment_file == Path.join(workspace.path, ".symphony/issue_comment.md")
    assert File.read!(workspace.comment_file) == ""

    {origin_url, 0} =
      System.cmd("git", ["-C", workspace.path, "remote", "get-url", "origin"], stderr_to_stdout: true)

    assert String.trim(origin_url) == "git@github.com:RaistlinMuc/symphony.git"
  end

  test "prompt builder includes repo, issue, and comment file instructions" do
    {:ok, project} =
      Project.new(%{
        "name" => "PromptProject",
        "repo_path" => "/tmp/prompt-project",
        "provider" => "github",
        "mode" => "full_agent",
        "provider_config" => %{
          "owner" => "RaistlinMuc",
          "repo" => "symphony"
        }
      })

    issue =
      issue_fixture(
        identifier: "#99",
        title: "Write a joke comment",
        description: "Tell a joke on the issue",
        labels: ["todo", "fun"]
      )

    prompt =
      MultiProjectPromptBuilder.build_prompt(project, issue, "/tmp/workspace", comment_file: "/tmp/workspace/.symphony/issue_comment.md")

    assert prompt =~ "Repository: RaistlinMuc/symphony"
    assert prompt =~ "Issue: #99 - Write a joke comment"
    assert prompt =~ "Labels: todo, fun"
    assert prompt =~ "/tmp/workspace/.symphony/issue_comment.md"
    assert prompt =~ "`gh` CLI is available"
  end

  defp create_repo_fixture(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-full-agent-#{name}-#{System.unique_integer([:positive])}"
      )

    repo_path = Path.join(root, "repo")
    workspace_root = Path.join(root, "workspaces")

    File.mkdir_p!(repo_path)
    File.write!(Path.join(repo_path, "README.md"), "fixture #{name}\n")
    System.cmd("git", ["-C", repo_path, "init", "-b", "main"], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_path, "config", "user.name", "Test User"], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_path, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_path, "add", "README.md"], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_path, "commit", "-m", "initial"], stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf(root) end)

    {repo_path, workspace_root}
  end

  defp issue_fixture(attrs) do
    attrs = Map.new(attrs)

    %Issue{
      id: Map.get(attrs, :id, "issue:77"),
      identifier: Map.get(attrs, :identifier, "#42"),
      title: Map.get(attrs, :title, "Test issue"),
      description: Map.get(attrs, :description, "Issue body"),
      state: Map.get(attrs, :state, "open"),
      url: Map.get(attrs, :url, "https://example.test/issues/42"),
      updated_at: Map.get(attrs, :updated_at, ~U[2026-03-06 01:00:00Z]),
      branch_name: Map.get(attrs, :branch_name, nil),
      labels: Map.get(attrs, :labels, ["todo"]),
      source: Map.get(attrs, :source, :issue)
    }
  end
end
