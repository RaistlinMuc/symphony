defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Project, ProjectDiscovery, ProjectRegistry}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Monitored projects</h2>
              <p class="section-copy">Configured projects with readiness and mode.</p>
            </div>
          </div>

          <%= if @payload.projects == [] do %>
            <p class="empty-state">No monitored projects configured.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 900px;">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Provider</th>
                    <th>Mode</th>
                    <th>State</th>
                    <th>Repo</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @payload.projects}>
                    <td><%= project.name %></td>
                    <td><%= project.provider %></td>
                    <td><%= project.mode %></td>
                    <td>
                      <span class={if project.readiness.ready and project.enabled, do: "state-badge state-badge-active", else: "state-badge state-badge-warning"}>
                        <%= project_status_label(project) %>
                      </span>
                      <div :if={project.readiness.missing_fields != []} class="muted">
                        missing: <%= Enum.join(project.readiness.missing_fields, ", ") %>
                      </div>
                    </td>
                    <td class="mono"><%= project.repo_path %></td>
                    <td>
                      <div class="detail-stack">
                        <button
                          type="button"
                          class="subtle-button"
                          data-url={"/api/v1/projects/#{project.id}/#{if project.enabled, do: "disable", else: "enable"}"}
                          onclick="fetch(this.dataset.url, {method: 'POST'}).then(() => window.location.reload())"
                        >
                          <%= if project.enabled, do: "Disable", else: "Enable" %>
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          data-url={"/api/v1/projects/#{project.id}"}
                          onclick="if (confirm('Delete project?')) { fetch(this.dataset.url, {method: 'DELETE'}).then(() => window.location.reload()) }"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Discovered projects</h2>
              <p class="section-copy">Detected from Codex workspace roots, sorted by latest activity.</p>
            </div>
          </div>

          <%= if @payload.discovered_projects == [] do %>
            <p class="empty-state">No Git repositories discovered from Codex state.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 980px;">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Active in Codex</th>
                    <th>Branch</th>
                    <th>Last changed</th>
                    <th>Path</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @payload.discovered_projects}>
                    <td><%= project.name %></td>
                    <td><%= if project.is_active, do: "yes", else: "no" %></td>
                    <td><%= project.git.branch || "n/a" %></td>
                    <td class="mono"><%= project.git.last_changed_at || "n/a" %></td>
                    <td class="mono"><%= project.path %></td>
                    <td>
                      <button
                        type="button"
                        class="subtle-button"
                        data-payload={Jason.encode!(default_create_payload(project))}
                        onclick="fetch('/api/v1/projects', {method: 'POST', headers: {'content-type': 'application/json'}, body: this.dataset.payload}).then(() => window.location.reload())"
                      >
                        Monitor
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    Map.merge(payload, %{
      projects: monitored_projects_payload(),
      discovered_projects: ProjectDiscovery.list()
    })
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp monitored_projects_payload do
    ProjectRegistry.list()
    |> Enum.map(fn project ->
      %{
        id: project.id,
        name: project.name,
        provider: project.provider,
        mode: project.mode,
        enabled: project.enabled,
        repo_path: project.repo_path,
        readiness: Project.readiness(project)
      }
    end)
  end

  defp default_create_payload(discovered_project) do
    %{path: path, git: git} = discovered_project
    remote = List.first(git.remote_urls || [])
    provider = default_provider_from_remote(remote)

    %{
      name: discovered_project.name,
      repo_path: path,
      enabled: true,
      mode: "build_only",
      provider: provider,
      provider_config: default_provider_config(provider, remote),
      build: %{"commands" => ["make test"], "workdir" => nil, "timeout_ms" => 900_000},
      ticket_mapping: %{"defaults_profile" => if(provider == "gitlab", do: "gitlab_default", else: "github_default"), "overrides" => %{}}
    }
  end

  defp default_provider_from_remote(remote) when is_binary(remote) do
    if String.contains?(String.downcase(remote), "git.pq-computers.com"), do: "gitlab", else: "github"
  end

  defp default_provider_from_remote(_), do: "github"

  defp default_provider_config("gitlab", remote) do
    %{
      "base_url" => "https://git.pq-computers.com",
      "project_path" => parse_gitlab_project_path(remote),
      "project_id" => nil,
      "token_env" => "GITLAB_TOKEN"
    }
  end

  defp default_provider_config("github", remote) do
    {owner, repo} = parse_github_owner_repo(remote)

    %{
      "owner" => owner,
      "repo" => repo,
      "api_base_url" => "https://api.github.com",
      "token_env" => "GITHUB_TOKEN"
    }
  end

  defp parse_github_owner_repo(remote) when is_binary(remote) do
    normalized = remote |> String.replace("git@github.com:", "https://github.com/") |> String.trim_trailing(".git")

    case URI.parse(normalized) do
      %URI{host: "github.com", path: path} when is_binary(path) ->
        case String.split(String.trim_leading(path, "/"), "/", parts: 3) do
          [owner, repo | _] -> {owner, repo}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp parse_github_owner_repo(_), do: {nil, nil}

  defp parse_gitlab_project_path(remote) when is_binary(remote) do
    remote
    |> String.replace("git@git.pq-computers.com:", "")
    |> String.replace("https://git.pq-computers.com/", "")
    |> String.trim_trailing(".git")
  end

  defp parse_gitlab_project_path(_), do: nil

  defp project_status_label(project) do
    cond do
      not project.enabled -> "disabled"
      project.readiness.ready -> "ready"
      true -> "needs_input"
    end
  end
end
