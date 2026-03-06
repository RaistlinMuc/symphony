# Changelog

All notable changes to this fork are documented in this file.

## [Unreleased]

### Added
- Multi-project monitor for GitHub and GitLab projects in the Elixir implementation.
- Project discovery from Codex global state (`~/.codex/.codex-global-state.json`).
- Persistent monitored project registry at `~/.codex/symphony/projects.json`.
- New project management API endpoints under `/api/v1/projects/*`.
- New tracker adapters and routing for GitHub and GitLab.
- Multi-project orchestration runtime with per-project polling/backoff/build execution.
- Full-agent workspace cloning and prompt generation for GitHub/GitLab issue runs.
- Dashboard sections for discovered and monitored projects.
- Regression tests for project registry and project discovery.
- Regression tests for multi-project workspace and full-agent execution.

### Changed
- Updated root and Elixir README to describe fork-specific behavior and setup.
- Extended observability payloads to include optional project context fields.
- Fixed build command timeout handling to use task-based timeouts instead of invalid `System.cmd/3`
  options.
- Added automatic trigger-label removal after successful or failed runs to avoid comment spam and
  retry loops.

### Notes
- Legacy Linear single-workflow path remains available.
- `build_only` mode is fully wired.
- `full_agent` mode now runs a real Codex workflow and posts the generated issue comment back to
  the tracker.
