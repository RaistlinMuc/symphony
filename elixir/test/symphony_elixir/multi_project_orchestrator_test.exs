defmodule SymphonyElixir.MultiProjectOrchestratorTest do
  use ExUnit.Case

  alias SymphonyElixir.MultiProjectOrchestrator
  alias SymphonyElixir.Tracker.Issue

  test "run_command_for_test executes successful commands" do
    assert {:ok, "ok"} =
             MultiProjectOrchestrator.run_command_for_test("printf 'ok'", File.cwd!(), 5_000)
  end

  test "run_command_for_test returns exit status failures" do
    assert {:error, {:exit_status, 7, output}} =
             MultiProjectOrchestrator.run_command_for_test("echo fail && exit 7", File.cwd!(), 5_000)

    assert output =~ "fail"
  end

  test "issue_signature_for_test ignores updated_at changes and label order" do
    issue_a = issue_fixture(updated_at: ~U[2026-03-06 01:00:00Z], labels: ["todo", "bug"])
    issue_b = issue_fixture(updated_at: ~U[2026-03-06 01:10:00Z], labels: ["bug", "todo"])

    assert MultiProjectOrchestrator.issue_signature_for_test(issue_a) ==
             MultiProjectOrchestrator.issue_signature_for_test(issue_b)
  end

  test "issue_signature_for_test changes when issue content changes" do
    issue_a = issue_fixture(description: "first body")
    issue_b = issue_fixture(description: "second body")

    refute MultiProjectOrchestrator.issue_signature_for_test(issue_a) ==
             MultiProjectOrchestrator.issue_signature_for_test(issue_b)
  end

  test "track_issues_for_test drops stale issues that are no longer filtered" do
    stale_issue = issue_fixture(id: "issue:1", title: "stale")
    current_issue = issue_fixture(id: "issue:2", title: "current")

    existing = %{
      stale_issue.id => MultiProjectOrchestrator.issue_signature_for_test(stale_issue)
    }

    tracked = MultiProjectOrchestrator.track_issues_for_test(existing, [current_issue])

    assert tracked == %{
             current_issue.id => MultiProjectOrchestrator.issue_signature_for_test(current_issue)
           }
  end

  defp issue_fixture(attrs) do
    attrs = Map.new(attrs)

    %Issue{
      id: Map.get(attrs, :id, "issue:42"),
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
