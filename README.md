# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Fork Changes (RaistlinMuc)

This fork extends the Elixir implementation with a practical multi-project monitor for Git-based
ticket workflows.

Implemented additions:

- Multi-project discovery from local Codex state (`~/.codex/.codex-global-state.json`)
- Monitored project CRUD persisted at `~/.codex/symphony/projects.json`
- GitHub and GitLab tracker adapters (including `https://git.pq-computers.com`)
- Dashboard sections for discovered and monitored projects
- New REST endpoints under `/api/v1/projects/*`
- Per-project run mode (`build_only` and `full_agent` config values)

Notes:

- Legacy Linear-based single-workflow mode remains available.
- In the current fork state, `build_only` is fully wired. `full_agent` is present as a mode and
  config path and currently executes the same build job pipeline.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

For this fork-specific behavior and APIs, see the added sections in
[elixir/README.md](elixir/README.md).

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
