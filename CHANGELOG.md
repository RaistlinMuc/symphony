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
- Dashboard sections for discovered and monitored projects.
- Regression tests for project registry and project discovery.

### Changed
- Updated root and Elixir README to describe fork-specific behavior and setup.
- Extended observability payloads to include optional project context fields.

### Notes
- Legacy Linear single-workflow path remains available.
- `build_only` mode is fully wired.
- `full_agent` mode exists as configuration and currently follows the same build pipeline in this fork revision.
