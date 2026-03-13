defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.History
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec history(Conn.t(), map()) :: Conn.t()
  def history(conn, params) do
    opts =
      []
      |> maybe_add_filter(:outcome, params["outcome"])
      |> maybe_add_filter(:limit, parse_int(params["limit"], 100))
      |> maybe_add_filter(:offset, parse_int(params["offset"], 0))

    runs = History.list_runs(opts)
    json(conn, %{runs: Enum.map(runs, &run_payload/1), count: length(runs)})
  end

  @spec history_for_issue(Conn.t(), map()) :: Conn.t()
  def history_for_issue(conn, %{"issue_identifier" => identifier}) do
    runs = History.runs_for_issue(identifier)
    json(conn, %{issue_identifier: identifier, runs: Enum.map(runs, &run_payload/1), count: length(runs)})
  end

  @spec metrics(Conn.t(), map()) :: Conn.t()
  def metrics(conn, _params) do
    json(conn, %{
      success_rate: History.success_rate(),
      avg_score: History.avg_score(),
      total_tokens: History.total_tokens(),
      total_runs: length(History.list_runs(limit: 10_000)),
      success_rate_by_label: History.success_rate_by_label()
    })
  end

  @spec failure_modes(Conn.t(), map()) :: Conn.t()
  def failure_modes(conn, _params) do
    json(conn, %{failure_modes: History.failure_breakdown()})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp run_payload(run) do
    %{
      id: run.id,
      issue_identifier: run.issue_identifier,
      issue_title: run.issue_title,
      issue_priority: run.issue_priority,
      issue_labels: run.issue_labels,
      started_at: run.started_at,
      finished_at: run.finished_at,
      outcome: run.outcome,
      agent_backend: run.agent_backend,
      turns_used: run.turns_used,
      total_tokens: run.total_tokens,
      wall_clock_ms: run.wall_clock_ms,
      final_phase: run.final_phase,
      eval_score: run.eval_score,
      eval_pr_created: run.eval_pr_created,
      eval_pr_url: run.eval_pr_url,
      eval_ci_status: run.eval_ci_status,
      error_message: run.error_message,
      error_category: run.error_category
    }
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil, default), do: default
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(_, default), do: default
end
