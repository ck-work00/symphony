defmodule SymphonyElixir.History do
  @moduledoc """
  Query interface for run history and aggregate metrics.
  """

  import Ecto.Query
  alias SymphonyElixir.Repo
  alias SymphonyElixir.History.{Run, RunEvent}

  # ---------------------------------------------------------------------------
  # Write operations
  # ---------------------------------------------------------------------------

  @spec record_dispatch(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_dispatch(attrs) do
    attrs
    |> Run.create_changeset()
    |> Repo.insert()
  end

  @spec record_completion(Run.t() | String.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_completion(%Run{} = run, attrs) do
    run
    |> Run.completion_changeset(attrs)
    |> Repo.update()
  end

  def record_completion(run_id, attrs) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> record_completion(run, attrs)
    end
  end

  @spec record_evaluation(Run.t() | String.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_evaluation(%Run{} = run, attrs) do
    run
    |> Run.evaluation_changeset(attrs)
    |> Repo.update()
  end

  def record_evaluation(run_id, attrs) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> record_evaluation(run, attrs)
    end
  end

  @spec record_escalation(String.t(), String.t(), String.t() | nil) ::
          {:ok, Run.t()} | {:error, term()}
  def record_escalation(run_id, escalation_type, message \\ nil) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        attrs = %{
          escalation_type: escalation_type,
          escalated_at: DateTime.utc_now(),
          needs_human: escalation_type == "needs_human",
          needs_human_message: message
        }

        run
        |> Run.completion_changeset(attrs)
        |> Repo.update()
    end
  end

  @spec record_event(map()) :: {:ok, RunEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(attrs) do
    attrs
    |> RunEvent.changeset()
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Read operations
  # ---------------------------------------------------------------------------

  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @spec get_run!(String.t()) :: Run.t()
  def get_run!(id), do: Repo.get!(Run, id)

  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(opts \\ []) do
    Run
    |> apply_filters(opts)
    |> order_by([r], desc: r.started_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc "Delete failed runs for an issue so the judge re-evaluates from scratch."
  @spec delete_failed_runs(String.t()) :: :ok
  def delete_failed_runs(issue_identifier) do
    run_ids =
      Run
      |> where([r], r.issue_identifier == ^issue_identifier and r.outcome == "failed")
      |> select([r], r.id)
      |> Repo.all()

    if run_ids != [] do
      RunEvent |> where([e], e.run_id in ^run_ids) |> Repo.delete_all()
      Run |> where([r], r.id in ^run_ids) |> Repo.delete_all()
    end

    :ok
  end

  @spec delete_all_runs(String.t()) :: :ok
  def delete_all_runs(issue_identifier) do
    run_ids =
      Run
      |> where([r], r.issue_identifier == ^issue_identifier)
      |> select([r], r.id)
      |> Repo.all()

    if run_ids != [] do
      RunEvent |> where([e], e.run_id in ^run_ids) |> Repo.delete_all()
      Run |> where([r], r.id in ^run_ids) |> Repo.delete_all()
    end

    :ok
  end

  @spec runs_for_issue(String.t()) :: [Run.t()]
  def runs_for_issue(issue_identifier) do
    Run
    |> where([r], r.issue_identifier == ^issue_identifier)
    |> order_by([r], desc: r.started_at)
    |> Repo.all()
  end

  @spec events_for_run(String.t()) :: [RunEvent.t()]
  def events_for_run(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], asc: e.timestamp)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Issue-level summary (for PhaseJudge)
  # ---------------------------------------------------------------------------

  @spec issue_summary(String.t()) :: map()
  def issue_summary(issue_identifier) do
    runs = runs_for_issue(issue_identifier)
    run_ids = Enum.map(runs, & &1.id)

    events =
      if run_ids != [] do
        RunEvent
        |> where([e], e.run_id in ^run_ids)
        |> order_by([e], asc: e.timestamp)
        |> Repo.all()
      else
        []
      end

    last_completed_at =
      runs
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.max_by(&DateTime.to_unix(&1.finished_at), fn -> nil end)
      |> then(fn r -> r && r.finished_at end)

    %{
      total_runs: length(runs),
      runs: runs,
      events: events,
      has_pr: Enum.any?(runs, &(&1.eval_pr_url != nil)),
      pr_url: runs |> Enum.find_value(& &1.eval_pr_url),
      has_evidence: Enum.any?(runs, &(&1.eval_evidence_posted == true)),
      has_tests: Enum.any?(runs, &(&1.eval_tests_written == true)),
      phases_seen: events |> extract_phases_from_events(),
      screenshots: events |> Enum.filter(&(&1.event_type == "screenshot_captured")),
      latest_outcome: runs |> List.first() |> then(fn r -> r && r.outcome end),
      last_completed_at: last_completed_at
    }
  end

  defp extract_phases_from_events(events) do
    events
    |> Enum.filter(&(&1.event_type == "phase_change"))
    |> Enum.map(fn e -> Map.get(e.payload || %{}, "to") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Aggregate metrics
  # ---------------------------------------------------------------------------

  @spec success_rate(keyword()) :: float()
  def success_rate(opts \\ []) do
    query = completed_runs_query(opts)

    total = Repo.aggregate(query, :count)
    successful = Repo.aggregate(where(query, [r], r.outcome == "completed"), :count)

    if total > 0, do: successful / total * 100.0, else: 0.0
  end

  @spec avg_score(keyword()) :: float()
  def avg_score(opts \\ []) do
    completed_runs_query(opts)
    |> where([r], not is_nil(r.eval_score))
    |> Repo.aggregate(:avg, :eval_score)
    |> then(fn
      nil -> 0.0
      avg -> avg / 1.0
    end)
  end

  @spec total_tokens(keyword()) :: integer()
  def total_tokens(opts \\ []) do
    completed_runs_query(opts)
    |> Repo.aggregate(:sum, :total_tokens)
    |> then(fn
      nil -> 0
      n -> n
    end)
  end

  @spec failure_breakdown(keyword()) :: [%{category: String.t(), count: integer()}]
  def failure_breakdown(opts \\ []) do
    completed_runs_query(opts)
    |> where([r], r.outcome == "failed")
    |> group_by([r], r.error_category)
    |> select([r], %{category: r.error_category, count: count()})
    |> order_by([r], desc: count())
    |> Repo.all()
  end

  @spec success_rate_by_label(keyword()) :: [%{label: String.t(), rate: float(), count: integer()}]
  def success_rate_by_label(opts \\ []) do
    # SQLite doesn't support unnest, so we do this in Elixir
    runs =
      completed_runs_query(opts)
      |> select([r], %{outcome: r.outcome, labels: r.issue_labels})
      |> Repo.all()

    runs
    |> Enum.flat_map(fn run ->
      Enum.map(run.labels || [], fn label -> {label, run.outcome} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {label, outcomes} ->
      total = length(outcomes)
      successful = Enum.count(outcomes, &(&1 == "completed"))
      %{label: label, rate: successful / total * 100.0, count: total}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @spec recent_completed(integer()) :: [Run.t()]
  def recent_completed(limit \\ 20) do
    Run
    |> where([r], not is_nil(r.finished_at))
    |> order_by([r], desc: r.finished_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp completed_runs_query(opts) do
    Run
    |> where([r], not is_nil(r.finished_at))
    |> apply_filters(opts)
  end

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_outcome(Keyword.get(opts, :outcome))
    |> maybe_filter_after(Keyword.get(opts, :after))
    |> maybe_filter_before(Keyword.get(opts, :before))
    |> maybe_filter_issue(Keyword.get(opts, :issue_identifier))
    |> maybe_filter_min_score(Keyword.get(opts, :min_score))
  end

  defp maybe_filter_outcome(query, nil), do: query
  defp maybe_filter_outcome(query, outcome), do: where(query, [r], r.outcome == ^outcome)

  defp maybe_filter_after(query, nil), do: query

  defp maybe_filter_after(query, %Date{} = date) do
    {:ok, dt} = NaiveDateTime.new(date, ~T[00:00:00])
    where(query, [r], r.started_at >= ^dt)
  end

  defp maybe_filter_after(query, %DateTime{} = dt), do: where(query, [r], r.started_at >= ^dt)

  defp maybe_filter_before(query, nil), do: query

  defp maybe_filter_before(query, %Date{} = date) do
    {:ok, dt} = NaiveDateTime.new(date, ~T[23:59:59])
    where(query, [r], r.started_at <= ^dt)
  end

  defp maybe_filter_before(query, %DateTime{} = dt), do: where(query, [r], r.started_at <= ^dt)

  defp maybe_filter_issue(query, nil), do: query
  defp maybe_filter_issue(query, id), do: where(query, [r], r.issue_identifier == ^id)

  defp maybe_filter_min_score(query, nil), do: query
  defp maybe_filter_min_score(query, score), do: where(query, [r], r.eval_score >= ^score)
end
