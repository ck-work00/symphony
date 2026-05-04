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
  alias SymphonyElixir.Planning.{Auditor, Plan, Planner, Grader, Dispatch}

  @type assess_result ::
          {:has_open_rows, Plan.t(), [map()]}
          | {:complete, Plan.t()}

  @doc """
  Read-only assessment of whether the plan has open rows.

    * If no plan exists for the issue, generate one (single LLM call) and
      return its open-row state.
    * If a plan exists with `missing` or `partial` rows, return
      `{:has_open_rows, plan, rows}`.
    * If every row is `done` or `deferred`, return `{:complete, plan}`.

  This does NOT create a `Dispatch` row — call `start_implement_dispatch/3`
  separately when the orchestrator commits to dispatching a worker against
  these rows.
  """
  @spec assess(map(), keyword()) :: {:ok, assess_result()} | {:error, term()}
  def assess(issue, opts \\ []) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    plan_result =
      case Planning.get_plan_by_issue(identifier) do
        nil ->
          # Fresh plan — run the Auditor first so the Planner sees what's
          # already on the WIP branch, and feed the summary in as
          # :audit_summary. Auditor failures don't block planning; we just
          # plan from the issue body alone.
          audit_summary =
            case Auditor.audit(issue, pr_url: opts[:pr_url]) do
              {:ok, summary} ->
                summary

              {:error, reason} ->
                Logger.warning("Auditor failed for #{identifier}: #{inspect(reason)}; planning from issue body only")
                nil
            end

          Planner.plan(issue, Keyword.put(opts, :audit_summary, audit_summary))

        %Plan{} = plan ->
          {:ok, plan}
      end

    case plan_result do
      {:ok, plan} ->
        case Plan.open_rows(plan) do
          [] -> {:ok, {:complete, plan}}
          rows -> {:ok, {:has_open_rows, plan, rows}}
        end

      err ->
        err
    end
  end

  @doc """
  Record the start of a worker dispatch.

  Call this only after `assess/2` returned `{:has_open_rows, plan, rows}`
  AND the orchestrator has committed to dispatching a worker. Creates a
  `Dispatch` row with the assigned rows, ready for the Grader to find
  later.
  """
  @spec start_implement_dispatch(Plan.t(), [map()], keyword()) ::
          {:ok, Dispatch.t()} | {:error, term()}
  def start_implement_dispatch(%Plan{} = plan, rows, opts \\ []) do
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
