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
    |> then(fn nil -> 0; n -> n end)
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
