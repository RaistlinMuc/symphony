defmodule SymphonyElixir.ProjectRegistryDiscoveryTest do
  use ExUnit.Case

  alias SymphonyElixir.{Project, ProjectDiscovery, ProjectRegistry}
  alias SymphonyElixir.Tracker.GitHub.Auth, as: GitHubAuth

  setup do
    tmp_root = Path.join(System.tmp_dir!(), "symphony-multi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_root)

    registry_path = Path.join(tmp_root, "projects.json")
    codex_state_path = Path.join(tmp_root, ".codex-global-state.json")

    previous_registry_path = Application.get_env(:symphony_elixir, :projects_registry_path)
    previous_codex_state_path = Application.get_env(:symphony_elixir, :codex_global_state_path)

    Application.put_env(:symphony_elixir, :projects_registry_path, registry_path)
    Application.put_env(:symphony_elixir, :codex_global_state_path, codex_state_path)

    on_exit(fn ->
      restore_env(:projects_registry_path, previous_registry_path)
      restore_env(:codex_global_state_path, previous_codex_state_path)
      File.rm_rf(tmp_root)
    end)

    {:ok, %{tmp_root: tmp_root, registry_path: registry_path, codex_state_path: codex_state_path}}
  end

  test "project readiness validates required fields and token", %{tmp_root: tmp_root} do
    repo_path = Path.join(tmp_root, "repo-ready")
    init_git_repo!(repo_path)

    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "token")

    on_exit(fn ->
      if is_nil(previous_token), do: System.delete_env("GITHUB_TOKEN"), else: System.put_env("GITHUB_TOKEN", previous_token)
    end)

    {:ok, project} =
      Project.new(%{
        "name" => "repo-ready",
        "repo_path" => repo_path,
        "provider" => "github",
        "provider_config" => %{"owner" => "openai", "repo" => "symphony", "token_env" => "GITHUB_TOKEN"},
        "build" => %{"commands" => ["echo test"]}
      })

    readiness = Project.readiness(project)
    assert readiness.ready
    assert readiness.missing_fields == []
  end

  test "project registry CRUD persists to disk", %{registry_path: registry_path, tmp_root: tmp_root} do
    repo_path = Path.join(tmp_root, "repo-crud")
    init_git_repo!(repo_path)

    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "token")

    on_exit(fn ->
      if is_nil(previous_token), do: System.delete_env("GITHUB_TOKEN"), else: System.put_env("GITHUB_TOKEN", previous_token)
    end)

    name = Module.concat(__MODULE__, Registry)
    {:ok, _pid} = ProjectRegistry.start_link(name: name)

    {:ok, created} =
      ProjectRegistry.create(
        %{
          "name" => "repo-crud",
          "repo_path" => repo_path,
          "provider" => "github",
          "provider_config" => %{"owner" => "openai", "repo" => "symphony", "token_env" => "GITHUB_TOKEN"},
          "build" => %{"commands" => ["echo hi"]}
        },
        name
      )

    assert File.exists?(registry_path)

    {:ok, updated} = ProjectRegistry.update(created.id, %{"mode" => "full_agent"}, name)
    assert updated.mode == "full_agent"

    {:ok, readiness} = ProjectRegistry.readiness(created.id, name)
    assert readiness.ready

    assert :ok = ProjectRegistry.delete(created.id, name)
    assert {:error, :not_found} = ProjectRegistry.get(created.id, name)
  end

  test "project discovery reads codex state, filters git repos and sorts with active first", %{
    tmp_root: tmp_root,
    codex_state_path: codex_state_path
  } do
    active_repo = Path.join(tmp_root, "active-repo")
    passive_repo = Path.join(tmp_root, "passive-repo")
    non_repo = Path.join(tmp_root, "not-a-repo")

    init_git_repo!(active_repo)
    init_git_repo!(passive_repo)
    File.mkdir_p!(non_repo)

    File.write!(
      codex_state_path,
      Jason.encode!(%{
        "electron-saved-workspace-roots" => [active_repo, passive_repo, non_repo],
        "active-workspace-roots" => [active_repo]
      })
    )

    discovered = ProjectDiscovery.list()

    assert length(discovered) == 2
    [first | _] = discovered
    assert first.path == Path.expand(active_repo)
    assert first.is_active == true

    assert Enum.any?(discovered, fn entry -> entry.path == Path.expand(passive_repo) end)
    refute Enum.any?(discovered, fn entry -> entry.path == Path.expand(non_repo) end)
  end

  test "github auth falls back to gh cli token", %{tmp_root: tmp_root} do
    bin_dir = Path.join(tmp_root, "bin")
    gh_path = Path.join(bin_dir, "gh")
    File.mkdir_p!(bin_dir)
    File.write!(gh_path, "#!/bin/sh\necho gho_test_token\n")
    File.chmod!(gh_path, 0o755)

    previous_path = System.get_env("PATH")
    previous_token = System.get_env("GITHUB_TOKEN")

    System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if is_nil(previous_path), do: System.delete_env("PATH"), else: System.put_env("PATH", previous_path)
      if is_nil(previous_token), do: System.delete_env("GITHUB_TOKEN"), else: System.put_env("GITHUB_TOKEN", previous_token)
    end)

    assert {:ok, "gho_test_token"} = GitHubAuth.token("GITHUB_TOKEN")
    assert GitHubAuth.available?("GITHUB_TOKEN")
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp init_git_repo!(path) do
    File.mkdir_p!(path)
    run!("git", ["init"], path)
    File.write!(Path.join(path, "README.md"), "# repo\n")
    run!("git", ["add", "README.md"], path)

    run!(
      "git",
      [
        "-c",
        "user.name=Codex",
        "-c",
        "user.email=codex@example.com",
        "commit",
        "-m",
        "init"
      ],
      path
    )
  end

  defp run!(command, args, cwd) do
    {output, code} = System.cmd(command, args, cd: cwd, stderr_to_stdout: true)
    if code != 0, do: flunk("command failed: #{command} #{Enum.join(args, " ")}\n#{output}")
    :ok
  end
end
