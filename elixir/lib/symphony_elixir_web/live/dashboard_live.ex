defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.History
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:active_tab, "live")
      |> assign(:history_runs, [])
      |> assign(:metrics, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :active_tab, tab)

    socket =
      case tab do
        "history" -> assign(socket, :history_runs, History.recent_completed(50))
        "metrics" -> assign(socket, :metrics, load_metrics())
        _ -> socket
      end

    {:noreply, socket}
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

      <nav class="tab-bar">
        <button
          :for={tab <- [{"live", "Live"}, {"history", "History"}, {"metrics", "Metrics"}]}
          class={"tab-button #{if @active_tab == elem(tab, 0), do: "tab-active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab={elem(tab, 0)}
        >
          <%= elem(tab, 1) %>
        </button>
      </nav>

      <%= if @active_tab == "live" do %>
        {render_live_tab(assigns)}
      <% end %>

      <%= if @active_tab == "history" do %>
        {render_history_tab(assigns)}
      <% end %>

      <%= if @active_tab == "metrics" do %>
        {render_metrics_tab(assigns)}
      <% end %>
    </section>
    """
  end

  defp render_live_tab(assigns) do
    ~H"""
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
                  <th>Phase</th>
                  <th>Session</th>
                  <th>Runtime / turns</th>
                  <th>Activity</th>
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
                    <span class={phase_badge_class(entry[:phase])}>
                      <%= entry[:phase] || entry.state %>
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
                      <%= if entry[:pr_url] do %>
                        <a class="pr-link" href={entry.pr_url} target="_blank"><%= short_pr_url(entry.pr_url) %></a>
                      <% end %>
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
            <h2 class="section-title">Completed work</h2>
            <p class="section-copy">Issues completed during this runtime session.</p>
          </div>
        </div>

        <%= if (@payload[:completed_history] || []) == [] do %>
          <p class="empty-state">No completed work yet.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 680px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Outcome</th>
                  <th>Phase</th>
                  <th>PR</th>
                  <th>Started</th>
                  <th>Completed</th>
                  <th>Turns</th>
                  <th>Tokens</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload[:completed_history] || []}>
                  <td>
                    <span class="issue-id"><%= entry.issue_identifier || entry.issue_id %></span>
                  </td>
                  <td>
                    <span class={outcome_badge_class(entry.outcome)}>
                      <%= entry.outcome %>
                    </span>
                  </td>
                  <td><%= entry[:phase] || "—" %></td>
                  <td>
                    <%= if entry[:pr_url] do %>
                      <a class="pr-link" href={entry.pr_url} target="_blank"><%= short_pr_url(entry.pr_url) %></a>
                    <% else %>
                      <span class="muted">—</span>
                    <% end %>
                  </td>
                  <td class="mono numeric"><%= format_timestamp(entry[:started_at]) %></td>
                  <td class="mono numeric"><%= format_timestamp(entry[:completed_at]) %></td>
                  <td class="numeric"><%= entry[:turn_count] || 0 %></td>
                  <td class="numeric"><%= format_int(entry[:tokens][:total_tokens] || 0) %></td>
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
    <% end %>
    """
  end

  defp render_history_tab(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">Run history</h2>
          <p class="section-copy">All completed runs across restarts, stored in the local database.</p>
        </div>
      </div>

      <%= if @history_runs == [] do %>
        <p class="empty-state">No historical runs recorded yet.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table" style="min-width: 860px;">
            <thead>
              <tr>
                <th>Issue</th>
                <th>Outcome</th>
                <th>Score</th>
                <th>Phase</th>
                <th>PR</th>
                <th>Duration</th>
                <th>Turns</th>
                <th>Tokens</th>
                <th>Error</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @history_runs}>
                <td>
                  <div class="issue-stack">
                    <span class="issue-id"><%= run.issue_identifier %></span>
                    <span class="muted"><%= truncate(run.issue_title, 40) %></span>
                  </div>
                </td>
                <td>
                  <span class={outcome_badge_class(run.outcome)}>
                    <%= run.outcome || "running" %>
                  </span>
                </td>
                <td>
                  <%= if run.eval_score do %>
                    <span class={score_badge_class(run.eval_score)}>
                      <%= run.eval_score %>
                    </span>
                  <% else %>
                    <span class="muted">—</span>
                  <% end %>
                </td>
                <td><%= run.final_phase || "—" %></td>
                <td>
                  <%= if run.eval_pr_url do %>
                    <a class="pr-link" href={run.eval_pr_url} target="_blank"><%= short_pr_url(run.eval_pr_url) %></a>
                  <% else %>
                    <span class="muted">—</span>
                  <% end %>
                </td>
                <td class="mono numeric"><%= format_duration_ms(run.wall_clock_ms) %></td>
                <td class="numeric"><%= run.turns_used || 0 %></td>
                <td class="numeric"><%= format_int(run.total_tokens || 0) %></td>
                <td>
                  <%= if run.error_category do %>
                    <span class="state-badge state-badge-danger"><%= run.error_category %></span>
                  <% else %>
                    <span class="muted">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  defp render_metrics_tab(assigns) do
    ~H"""
    <%= if @metrics do %>
      <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Success rate</p>
          <p class="metric-value numeric"><%= format_pct(@metrics.success_rate) %></p>
          <p class="metric-detail">Percentage of runs with "completed" outcome.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Avg score</p>
          <p class="metric-value numeric"><%= format_score(@metrics.avg_score) %></p>
          <p class="metric-detail">Average evaluation score (0–100) across completed runs.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Total runs</p>
          <p class="metric-value numeric"><%= format_int(@metrics.total_runs) %></p>
          <p class="metric-detail">All dispatches recorded in the database.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Total tokens</p>
          <p class="metric-value numeric"><%= format_int(@metrics.total_tokens) %></p>
          <p class="metric-detail">Cumulative tokens across all historical runs.</p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Failure modes</h2>
            <p class="section-copy">Breakdown of error categories for failed runs.</p>
          </div>
        </div>

        <%= if @metrics.failure_modes == [] do %>
          <p class="empty-state">No failures recorded.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 400px;">
              <thead>
                <tr>
                  <th>Category</th>
                  <th>Count</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={mode <- @metrics.failure_modes}>
                  <td>
                    <span class="state-badge state-badge-danger"><%= mode.category || "unknown" %></span>
                  </td>
                  <td class="numeric"><%= mode.count %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Success rate by label</h2>
            <p class="section-copy">How different issue labels perform with autonomous agents.</p>
          </div>
        </div>

        <%= if @metrics.by_label == [] do %>
          <p class="empty-state">No label data available.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 400px;">
              <thead>
                <tr>
                  <th>Label</th>
                  <th>Success rate</th>
                  <th>Runs</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @metrics.by_label}>
                  <td><span class="state-badge"><%= entry.label %></span></td>
                  <td class="numeric"><%= format_pct(entry.rate) %></td>
                  <td class="numeric"><%= entry.count %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    <% else %>
      <p class="empty-state">Loading metrics...</p>
    <% end %>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
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

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> format_timestamp(dt)
      _ -> iso
    end
  end

  defp format_timestamp(_), do: "—"

  defp short_pr_url(url) when is_binary(url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, url) do
      [_, repo, number] -> "#{repo}##{number}"
      _ -> url
    end
  end

  defp short_pr_url(_), do: ""

  defp phase_badge_class(nil), do: "state-badge"

  defp phase_badge_class(phase) do
    base = "state-badge"
    normalized = String.downcase(phase)

    cond do
      String.contains?(normalized, "investigate") -> "#{base} state-badge-warning"
      String.contains?(normalized, "implement") -> "#{base} state-badge-active"
      String.contains?(normalized, "test") -> "#{base} state-badge-active"
      String.contains?(normalized, "ship") -> "#{base} state-badge-active"
      String.contains?(normalized, "evidence") -> "#{base} state-badge-active"
      true -> base
    end
  end

  defp outcome_badge_class("completed"), do: "state-badge state-badge-active"
  defp outcome_badge_class("failed"), do: "state-badge state-badge-danger"
  defp outcome_badge_class(_), do: "state-badge"

  defp load_metrics do
    %{
      success_rate: History.success_rate(),
      avg_score: History.avg_score(),
      total_tokens: History.total_tokens(),
      total_runs: length(History.list_runs(limit: 10_000)),
      failure_modes: History.failure_breakdown(),
      by_label: History.success_rate_by_label()
    }
  end

  defp format_pct(nil), do: "—"
  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(value) when is_integer(value), do: "#{value}%"

  defp format_score(nil), do: "—"
  defp format_score(value) when is_number(value), do: "#{value}"

  defp format_duration_ms(nil), do: "—"

  defp format_duration_ms(ms) when is_integer(ms) do
    seconds = div(ms, 1_000)
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp truncate(nil, _max), do: ""
  defp truncate(str, max) when is_binary(str) and byte_size(str) <= max, do: str
  defp truncate(str, max) when is_binary(str), do: String.slice(str, 0, max) <> "..."

  defp score_badge_class(nil), do: "state-badge"
  defp score_badge_class(score) when score >= 70, do: "state-badge state-badge-active"
  defp score_badge_class(score) when score >= 40, do: "state-badge state-badge-warning"
  defp score_badge_class(_score), do: "state-badge state-badge-danger"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
