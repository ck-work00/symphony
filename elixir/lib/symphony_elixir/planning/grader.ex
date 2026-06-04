defmodule SymphonyElixir.Planning.Grader do
  @moduledoc """
  Grades a worker dispatch's diff against the rows it was assigned.

  The Grader is the load-bearing piece of the "premature-victory workaround":
  workers will declare done while their diff is still incomplete, so the
  orchestrator runs the Grader after EVERY dispatch and only trusts the
  Grader's verdict.

  Returns a structured grade JSON:

      %{
        "verdict" => "approve" | "request_changes" | "blocked",
        "rationale" => "one-paragraph summary",
        "rows" => [
          %{"id" => "R1", "state" => "done", "note" => "test/x.exs:42 covers it"},
          %{"id" => "R3", "state" => "partial", "note" => "missing the empty-state branch"}
        ]
      }

  The verdict is `approve` only if every assigned row is `done`. Any
  `partial` or `missing` row makes the verdict `request_changes`. `blocked`
  is reserved for "the dispatch couldn't even run" (test failure on
  unrelated code, broken slot, etc.).
  """

  require Logger

  alias SymphonyElixir.Claude.OneShot
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.Dispatch

  @grade_system_prompt """
  You are the grading component of an autonomous engineering orchestrator.

  Given a plan, the rows a worker was assigned, and a structured summary of
  the branch state (file list, line counts, commit subjects) plus optional
  test output, evaluate which rows are closed. Workers routinely overstate
  their progress, so be skeptical — but also know that `touches:` paths in
  the plan rows are GUESSES from the Planner that may not match the
  codebase's actual layout. Match by intent and filename pattern, not
  literal-string equality.

  Hard requirements:

  1. Reply with ONLY a JSON object. No prose. No code fences.
  2. The JSON shape is:

       {
         "verdict": "approve" | "request_changes" | "blocked",
         "rationale": "1-3 sentences explaining the verdict",
         "rows": [
           {
             "id": "R1",
             "state": "done" | "partial" | "missing",
             "note": "specific evidence: file path or commit SHA from the summary, or what's still missing"
           }
         ]
       }

  3. Include an entry for every assigned row, even if untouched.
  4. Verdict rules:
       - "approve": every assigned row state is "done"
       - "request_changes": at least one row is "partial" or "missing"
       - "blocked": the dispatch couldn't run at all (slot broken, tests
         crash on unrelated code, missing infrastructure). Use sparingly.
  5. `note` fields must cite specific evidence from the summary — the file
     name with stat line, or a commit SHA + subject. "Looks good" is not a
     note; "lib/gf_web/live/maintenance_view_live.ex (+1234 lines), commit
     ee303e2f 'C03 inline editors'" is.
  6. **Path matching is fuzzy.** A row that says
     `touches: ["assets/js/hooks/local_storage_state.ts"]` may correspond
     to an actual file at `assets/js/hooks/local_storage_draft.js` — same
     concept, different name. If the diff has a file whose path
     reasonably maps to the row's intent (matching basename pattern, same
     module/namespace, same described feature in the row description),
     count it as covering the row. Don't mark a row "missing" just because
     the literal path string isn't in the diff.
  7. **Commit subjects are first-class evidence.** A commit subject like
     `GEA-2772: C03-maintenance-view — inline editors` directly closes
     row `C03-maintenance-view`. Use commit subjects to confirm row
     closures even when files don't precisely match the row's `touches:`
     hints.
  8. **PR description is a separate evidence channel.** A row whose
     deliverable is a PR-body update (e.g. "Update PR description with
     per-contract status table", "Add Contract Audit section to PR
     description", "List deferrals on PR") will NOT appear in `git diff`
     — workers edit PR bodies via `gh pr edit --body`. If a "## PR
     description" section is present in the evidence below, scan it for
     the row's required content (status table, audit section, etc.) and
     mark `done` if present. **Do not mark such rows missing just
     because they don't appear in the diff** — that's the wrong evidence
     channel. If the PR description IS present and clearly contains
     what the row asked for, the row is `done`.
  9. If a row's diff exists but its test is missing, that row is `partial`,
     not `done`. The contract is "implementation + test", not "implementation
     alone".
  """

  @doc """
  Grade a dispatch and persist the result.

  Inputs:
    * `dispatch` — the `Dispatch.t()` row to grade. `assigned_rows_json`
      and `plan_id` must already be set.
    * `evidence`:
        * `:diff` — text of the worker's diff against the base branch
        * `:test_output` — text of the test run output
        * `:plan` — the parent `Plan.t()` (passed in to avoid a refetch)
        * `:notes` — optional extra context (e.g. "browser walkthrough
          screenshots attached on Linear")

  Returns the updated `Dispatch.t()` with `grade_json` populated.
  """
  @spec grade(Dispatch.t(), keyword()) :: {:ok, Dispatch.t()} | {:error, term()}
  def grade(%Dispatch{} = dispatch, evidence) do
    plan = Keyword.fetch!(evidence, :plan)

    user_prompt = build_user_prompt(dispatch, plan, evidence)

    with {:ok, grade_json} <- OneShot.request_json(@grade_system_prompt, user_prompt, evidence),
         :ok <- validate_shape(grade_json, dispatch),
         {:ok, updated} <- Planning.record_grade(dispatch, grade_json) do
      {:ok, updated}
    else
      {:error, _} = err ->
        Logger.error("Grader failed for dispatch=#{dispatch.id}: #{inspect(err)}")
        err
    end
  end

  defp build_user_prompt(dispatch, plan, evidence) do
    diff = Keyword.get(evidence, :diff, "")
    test_output = Keyword.get(evidence, :test_output, "")
    notes = Keyword.get(evidence, :notes, "")
    pr_body = Keyword.get(evidence, :pr_body)

    assigned = Map.get(dispatch.assigned_rows_json || %{}, "rows", [])
    plan_rows = Map.get(plan.plan_json || %{}, "rows", [])

    sections = [
      "## Plan (full context)\n\n```json\n#{Jason.encode!(plan_rows, pretty: true)}\n```",
      "## Rows assigned to this dispatch\n\n```json\n#{Jason.encode!(assigned, pretty: true)}\n```",
      "## Branch state vs base\n\nThis is a structured summary (file list + commit subjects + diff stats), NOT a full diff dump. Match `assigned_rows[*].touches` paths against the file list, and match row IDs / contract numbers against commit subjects.\n\n```\n#{truncate(diff, 200_000)}\n```",
      pr_body_section(pr_body),
      "## Test output\n\n```\n#{truncate(test_output, 20_000)}\n```",
      if(notes != "", do: "## Additional context\n\n#{notes}", else: nil)
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n---\n\n")
  end

  defp pr_body_section(nil), do: nil
  defp pr_body_section(""), do: nil

  defp pr_body_section(pr_body) do
    "## PR description (live from GitHub)\n\nUse this to evaluate rows whose deliverable is a PR-description edit (status tables, contract audits, deferral lists). Workers update PR descriptions via `gh pr edit --body`, which leaves no `git diff` trace — this section is the only evidence available for those rows.\n\n```json\n#{truncate(pr_body, 50_000)}\n```"
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "\n\n[...truncated]"
  end

  defp truncate(text, _) when is_binary(text), do: text
  defp truncate(_, _), do: ""

  defp validate_shape(%{"verdict" => v, "rows" => rows}, dispatch)
       when v in ["approve", "request_changes", "blocked"] and is_list(rows) do
    assigned_ids =
      dispatch.assigned_rows_json
      |> Map.get("rows", [])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    graded_ids = rows |> Enum.map(& &1["id"]) |> MapSet.new()

    cond do
      not Enum.all?(rows, &valid_row?/1) ->
        {:error, {:invalid_grade_shape, "rows missing required fields"}}

      not MapSet.subset?(assigned_ids, graded_ids) ->
        missing = MapSet.difference(assigned_ids, graded_ids) |> MapSet.to_list()
        {:error, {:invalid_grade_shape, "missing grades for rows: #{inspect(missing)}"}}

      true ->
        :ok
    end
  end

  defp validate_shape(_, _), do: {:error, {:invalid_grade_shape, "bad top-level keys"}}

  defp valid_row?(%{"id" => id, "state" => state})
       when is_binary(id) and state in ["done", "partial", "missing"],
       do: true

  defp valid_row?(_), do: false
end
