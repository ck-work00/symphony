defmodule SymphonyElixir.Planning.Planner do
  @moduledoc """
  Generates a structured plan for a Linear issue.

  The Planner runs once per issue (or re-runs when the issue body materially
  changes). Given:

    * the issue body
    * any in-repo process docs the issue references
    * the current branch diff against the base branch (if a WIP branch exists)

  it produces a plan with rows that workers can close one-by-one. Each row
  has a stable id, file-path hints, test hints, dependencies, and an initial
  state (`missing` for fresh issues, or `partial` / `done` if an audit
  determines the WIP branch already covers it).
  """

  require Logger

  alias SymphonyElixir.Claude.OneShot
  alias SymphonyElixir.Planning

  @plan_system_prompt """
  You are the planning component of an autonomous engineering orchestrator.

  Given a Linear issue body, optional in-repo process docs, and an optional
  diff summary describing existing work-in-progress, output a structured
  plan that downstream worker agents will execute one row at a time.

  Hard requirements:

  1. Reply with ONLY a JSON object. No prose. No code fences.
  2. The JSON must have shape:

       {
         "rows": [
           {
             "id": "R1",
             "description": "One-sentence description of what this row delivers.",
             "touches": ["lib/path/to/file.ex", "test/path/to/file_test.exs"],
             "tests": ["test/path/to/file_test.exs"],
             "depends_on": [],
             "state": "missing",
             "rationale": null
           }
         ],
         "out_of_scope": [],
         "notes": "Optional: one-paragraph context for graders."
       }

  3. Row IDs are short stable identifiers (R1, R2, ... or domain-meaningful
     like "issues-list-filters"). Reuse existing IDs if a prior plan was
     supplied as context.
  4. `touches` lists every file the row will create or modify. Workers use
     this to partition rows that don't collide on files.
  5. `state` is one of:
       - "missing": not started
       - "partial": some work exists but it's incomplete
       - "done": already implemented (only if audit signal proves it)
       - "deferred": reviewer-approved out-of-scope (rare; usually goes in
         `out_of_scope` instead).
     `rationale` is a short string when state is `partial` / `done`,
     describing the evidence; null otherwise.
  6. Rows must be small enough that a single worker dispatch can close one
     in 1-3 commits. Split big features.
  7. Do NOT defer rows on your own. If a row feels too big, split it. Only
     items the issue body explicitly trims belong in `out_of_scope`.
  8. Test rows mean in-repo automated tests only — ExUnit/LiveView tests under
     `test/**/*_test.exs`. These repos have NO in-repo Playwright/Cypress/e2e
     harness (no `e2e/` dir, no `playwright.config`, no `@playwright` dep), so a
     row whose deliverable is an `e2e/*.spec.ts` or any browser-spec file would
     be dead and unrunnable — never emit one. End-to-end browser behavior is
     verified live in the Test phase by a separate sub-agent driving system
     Playwright (`npx playwright`); that is the Test phase's job, not an
     implementation row, so do not add a plan row for it. For a UI change, the
     row's testable deliverable is the LiveView/ExUnit test.
  9. Parity migrations: plan the SHELL and INTEGRATION surface, not just content.
     The gaps a content-only plan misses live OUTSIDE the component's own file —
     in the app shell, the sibling pages, the router, and the interaction model.
     When the reference (e.g. React) renders a portal/sheet/modal, or is imported
     by more than one page, grep the reference for its call sites and interaction
     hooks and emit EXPLICIT rows for:
       - Interaction contract — how it mounts and dismisses: backdrop/scrim (or
         deliberately none), outside-click, Escape, focus, the back/close control.
         Name the reference's own guards (e.g. a pointer-down-outside +
         `isInteractiveTarget` handler) so the worker matches behavior, not guesses.
       - Responsive contract — what the layout does at each breakpoint, pinning the
         exact breakpoint token from the reference (do not guess `sm` vs `md`).
       - Call-site inventory — one row per surface that invokes the component (e.g.
         a notification bell on each section page), so the affordance exists
         everywhere the reference puts it, not only on the component's own route.
       - Routing contract — every URL that opens or closes it, the dismiss
         destination per entry point, and a safety-net route so a sibling path
         never crashes (an over-any-section `/:section/inbox`, not a `/:id`
         fall-through that casts "inbox" as a record id).
     A cross-cutting component (touches the layout shell or ≥2 sibling pages) is
     rarely one dispatch: split it along these seams, and say so in `notes`.

  Bias the plan toward what the issue body and process docs actually ask
  for. Do not invent rows the issue doesn't request.
  """

  @doc """
  Generate (or regenerate) a plan for the given issue and persist it.

  Inputs:
    * `issue` — a `SymphonyElixir.Linear.Issue` struct (or a map with the
      same shape)
    * `opts`:
        * `:process_docs` — list of `{path, content}` tuples for any
          in-repo process docs the issue references
        * `:audit_summary` — optional string summarizing the WIP branch's
          existing diff against the base, to seed `partial` / `done` states
        * `:prior_plan` — optional `Plan.t()` whose row IDs the new plan
          should preserve where rows still apply

  Returns the persisted `Plan.t()` on success.
  """
  @spec plan(map(), keyword()) :: {:ok, SymphonyElixir.Planning.Plan.t()} | {:error, term()}
  def plan(issue, opts \\ []) do
    user_prompt = build_user_prompt(issue, opts)

    with {:ok, plan_json} <- OneShot.request_json(@plan_system_prompt, user_prompt, opts),
         :ok <- validate_shape(plan_json),
         {:ok, plan} <-
           Planning.upsert_plan(%{
             issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
             issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
             status: "dispatching",
             plan_json: plan_json,
             metadata:
               (Keyword.get(opts, :metadata, %{}) || %{})
               |> Map.put("generated_at", DateTime.to_iso8601(DateTime.utc_now()))
           }) do
      # Post the plan to Linear so it's visible/reviewable (best-effort).
      {:ok, Planning.mirror_plan_to_linear(plan)}
    else
      {:error, _} = err ->
        Logger.error("Planner failed for issue=#{issue_id_for_log(issue)}: #{inspect(err)}")
        err
    end
  end

  defp build_user_prompt(issue, opts) do
    body = Map.get(issue, :description) || Map.get(issue, "description") || ""
    title = Map.get(issue, :title) || Map.get(issue, "title") || ""
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || ""
    labels = Map.get(issue, :labels) || Map.get(issue, "labels") || []

    process_docs = Keyword.get(opts, :process_docs, [])
    audit_summary = Keyword.get(opts, :audit_summary)
    prior_plan = Keyword.get(opts, :prior_plan)

    sections = [
      "## Linear issue\n\n- ID: #{identifier}\n- Title: #{title}\n- Labels: #{Enum.join(labels, ", ")}\n\n### Body\n\n#{body}",
      process_docs_section(process_docs),
      audit_section(audit_summary),
      prior_plan_section(prior_plan)
    ]

    sections |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n---\n\n")
  end

  defp process_docs_section([]), do: nil

  defp process_docs_section(docs) when is_list(docs) do
    rendered =
      Enum.map_join(docs, "\n\n", fn {path, content} ->
        "### #{path}\n\n#{content}"
      end)

    "## Process docs\n\n#{rendered}"
  end

  defp audit_section(nil), do: nil
  defp audit_section(""), do: nil

  defp audit_section(summary) when is_binary(summary) do
    "## WIP branch audit summary\n\n#{summary}\n\nUse this to mark rows `partial` or `done` where the WIP branch already covers them."
  end

  defp prior_plan_section(nil), do: nil

  defp prior_plan_section(%SymphonyElixir.Planning.Plan{plan_json: %{"rows" => rows}}) when is_list(rows) do
    encoded = Jason.encode!(rows, pretty: true)
    "## Prior plan rows (preserve IDs where possible)\n\n```json\n#{encoded}\n```"
  end

  defp prior_plan_section(_), do: nil

  defp validate_shape(%{"rows" => rows}) when is_list(rows) do
    if Enum.all?(rows, &valid_row?/1) do
      :ok
    else
      {:error, {:invalid_plan_shape, "rows missing required fields"}}
    end
  end

  defp validate_shape(_), do: {:error, {:invalid_plan_shape, "missing rows array"}}

  defp valid_row?(%{"id" => id, "description" => desc, "state" => state})
       when is_binary(id) and is_binary(desc) and state in ["missing", "partial", "done", "deferred"],
       do: true

  defp valid_row?(_), do: false

  defp issue_id_for_log(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"
  end
end
