defmodule SymphonyElixir.Planning.Workflow do
  @moduledoc """
  Plan-driven dispatch state machine.

  Replaces the artifact-based `PhaseJudge` for the Implement phase. Owns
  the lifecycle:

      planning → dispatching → grading → (done | redispatching → dispatching)

  Test, Share Evidence, and Simplify phases still go through `PhaseJudge`
  in the experiment branch; this module is concerned with the
  plan/grade/redispatch loop on top of Implement.

  Phase A scope (no fanout): a single worker dispatch closes all open rows
  on each pass. Phase B will partition rows across N workers.
  """

  require Logger

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Planner, Grader, Dispatch}

  @type assignment :: %{
          plan: Plan.t(),
          dispatch: Dispatch.t(),
          rows: [map()]
        }

  @type next_action ::
          :done
          | {:plan_then_dispatch, Plan.t()}
          | {:dispatch, assignment()}
          | {:no_open_rows, Plan.t()}

  @doc """
  Decide the next action for an issue.

    * If no plan exists, return `{:plan_then_dispatch, plan}` after generating one.
    * If the plan has open rows (`missing` or `partial`), return `{:dispatch, assignment}`.
    * If every row is `done` or `deferred`, return `:done`.

  The caller (orchestrator) is responsible for actually dispatching the
  worker once we hand back an assignment.
  """
  @spec next_action(map(), keyword()) :: {:ok, next_action()} | {:error, term()}
  def next_action(issue, opts \\ []) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    case Planning.get_plan_by_issue(identifier) do
      nil ->
        case Planner.plan(issue, opts) do
          {:ok, plan} ->
            decide_from_plan(plan)

          err ->
            err
        end

      %Plan{status: "done"} ->
        {:ok, :done}

      %Plan{} = plan ->
        decide_from_plan(plan)
    end
  end

  defp decide_from_plan(%Plan{} = plan) do
    open = Plan.open_rows(plan)

    if open == [] do
      {:ok, {:no_open_rows, plan}}
    else
      case start_dispatch(plan, open) do
        {:ok, dispatch} -> {:ok, {:dispatch, %{plan: plan, dispatch: dispatch, rows: open}}}
        err -> err
      end
    end
  end

  @doc """
  Record the start of a worker dispatch and return the persisted row.

  The caller passes `slot_name` once it's claimed; the dispatch is created
  with the assigned rows and started_at timestamp.
  """
  @spec start_dispatch(Plan.t(), [map()], keyword()) :: {:ok, Dispatch.t()} | {:error, term()}
  def start_dispatch(%Plan{} = plan, rows, opts \\ []) do
    Planning.record_dispatch(%{
      plan_id: plan.id,
      role: "implement",
      slot_name: Keyword.get(opts, :slot_name),
      assigned_rows_json: %{"rows" => rows},
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Grade a finished worker dispatch and update the plan with row-level results.

  Returns `{:ok, {:approve | :request_changes | :blocked, plan}}`.
  The verdict tells the orchestrator whether to advance phases or
  re-dispatch Implement with the still-open rows.
  """
  @spec grade_dispatch(Dispatch.t(), keyword()) ::
          {:ok, {atom(), Plan.t()}} | {:error, term()}
  def grade_dispatch(%Dispatch{} = dispatch, evidence) do
    plan = Keyword.fetch!(evidence, :plan)

    case Grader.grade(dispatch, evidence) do
      {:ok, %Dispatch{grade_json: grade_json}} ->
        verdict = String.to_atom(grade_json["verdict"])
        {:ok, updated_plan} = merge_grade_into_plan(plan, grade_json)
        {:ok, {verdict, updated_plan}}

      err ->
        err
    end
  end

  # Merge grader row states into the plan's row list. Each graded row updates
  # the matching plan row's `state` and `rationale`. Rows not in the grader
  # output are left untouched (e.g. rows from a different worker's slice).
  defp merge_grade_into_plan(%Plan{} = plan, grade_json) do
    by_id =
      grade_json
      |> Map.get("rows", [])
      |> Map.new(fn row -> {row["id"], row} end)

    updated_rows =
      Plan.rows(plan)
      |> Enum.map(fn row ->
        case Map.get(by_id, row["id"]) do
          nil ->
            row

          graded ->
            row
            |> Map.put("state", normalize_state(graded["state"]))
            |> Map.put("rationale", graded["note"] || row["rationale"])
        end
      end)

    Planning.replace_rows(plan, updated_rows)
  end

  defp normalize_state("done"), do: "done"
  defp normalize_state("partial"), do: "partial"
  defp normalize_state("missing"), do: "missing"
  defp normalize_state(_), do: "missing"

  @doc "Returns true if every row in the plan is `done` or `deferred`."
  @spec plan_complete?(Plan.t()) :: boolean()
  def plan_complete?(%Plan{} = plan) do
    Plan.rows(plan)
    |> Enum.all?(fn row -> row["state"] in ["done", "deferred"] end)
  end

  @doc """
  Mark a plan as `done` once the orchestrator has confirmed all rows are
  closed. The Test phase happens AFTER this — Workflow only owns Implement.
  """
  @spec mark_plan_done(Plan.t()) :: {:ok, Plan.t()} | {:error, term()}
  def mark_plan_done(%Plan{} = plan), do: Planning.set_plan_status(plan, "done")
end
