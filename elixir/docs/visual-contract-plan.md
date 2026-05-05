# Visual Contract — Implementation Plan

## Why

Wave 4 of the LV migration shipped 10 maintenance pages. They're functionally
green (`mix test` clean, behavior matches React) but visual parity drifts
silently — copy, spacing, badge variants, mobile layout. The Page Contract
captures behavior; nothing captures pixels.

The fix is to add **machine-checkable visual proxies** to the existing
plan-grade-redispatch loop, not to bolt on a heavyweight image-diff
service. The sweet spot is DOM/Tailwind-class assertions that ride in
`mix test` plus a Visual Contract sidecar the Planner consumes.

## Three tiers, ship in order

### Tier 1 — DOM class assertions in `mix test`

The cheapest, most useful, most permanent line of defense. Tailwind makes
visual parity ~80% checkable by string-matching class lists. If LV emits
the same classes at the same selectors as React, most layout/style
regressions die in CI, not in human review.

**Concrete deliverables:**

1. `test/gf_web/live/visual_helpers.ex` — `import`-able module with:
   - `assert_classes(html, selector, must_include: [String.t()])`
   - `refute_classes(html, selector, [String.t()])`
   - `assert_text_at(html, selector, expected)` (for copy parity)
   - Implementation: Floki parse + class-list split + `assert/2`.
2. Per-page LV test files gain a `describe "visual contract"` block with
   `assert_classes/3` calls for every named region (header, top-bar
   actions, filter chips, table headers, status badges, empty state,
   responsive containers).
3. The classes come from the **Visual Contract sidecar** (Tier 2).

### Tier 2 — Visual Contract sidecar in `docs/lv-migration/`

A new fillable template the worker completes from the React source, the
Planner reads, and the Grader uses to evaluate `visual_state` per row.

**Concrete deliverables:**

1. `docs/lv-migration/VISUAL_CONTRACT.md` — template with sections:
   ```
   ## Selector → required Tailwind classes

   | Selector | Description | Required classes |
   |----------|-------------|------------------|
   | `header.page-header` | Top page bar | flex items-center justify-between px-6 py-4 |
   | `[data-testid=status-badge]` | Status chip | rounded-full px-2 py-0.5 text-xs |

   ## Responsive breakpoints

   | Breakpoint | Layout shift |
   |------------|--------------|
   | < 640px (sm:) | stacked card layout, hide table |
   | 768-1280px | reduced columns |
   | ≥ 1280px | full table |

   ## States

   | State | Selector | Required copy | Notes |
   |-------|----------|---------------|-------|
   | empty | `[data-testid=empty]` | "No maintenance records" | centered, max-w-md |
   | loading | `[data-testid=loading]` | spinner | |

   ## Hover / focus / active

   ## Animations / transitions

   ## Copy parity

   Exact text strings the LV must emit (button labels, headings,
   placeholder text, flash messages). Workers diff this character-by-
   character against the React source.
   ```
2. `docs/lv-migration/README.md` updated to call out the sidecar.
3. `docs/lv-migration/WORKER_PROMPT.md` updated: "During Step 2 (fill
   contract), also fill `VISUAL_CONTRACT.md` for each page. The act of
   filling each row is the verification you read the React JSX. After
   implementation, every selector in the Visual Contract MUST appear in
   `assert_classes/3` calls in the LV test."
4. `docs/lv-migration/TESTER_PROMPT.md` updated: "Before APPROVE, confirm
   each Visual Contract row has a matching `assert_classes/3` test, and
   the LV's rendered HTML at the dev URL contains every required class
   on every selector. Also walk responsive breakpoints in the browser."

### Tier 3 — Pixel-diff screenshots (deferred)

Playwright takes screenshots of LV and React at multiple viewport widths,
runs `pixelmatch` with a tolerance, posts diff percentages in the Tester
Report. Catches font-rendering and animation issues Tier 1 misses, but is
flaky against anti-aliasing / font hinting.

Defer until Tiers 1 and 2 are paying off.

## Symphony plumbing

To carry visual evidence through the plan/grade/redispatch loop:

### Plan row schema (additive, JSON only — no migration)

Each `plan_json.rows[*]` gains optional fields:

```json
{
  "id": "C03-maintenance-view",
  "description": "...",
  "touches": [...],
  "tests": [...],
  "state": "missing | partial | done",
  "visual_assertions": [
    { "selector": "header.maintenance-header", "must_include": ["flex","items-center"] },
    { "selector": "[data-testid=status-badge]", "must_include": ["rounded-full","text-xs"] }
  ],
  "visual_state": "missing | partial | done"
}
```

`visual_state` is independent of `state`. A row can be functionally `done`
but visually `partial`. The Grader's verdict is `approve` only when both
are `done`.

### Planner system prompt update

Add a new rule:

> If `process_docs` includes a `VISUAL_CONTRACT.md` file (filled, not the
> template), or if the issue body references a Visual Contract artifact,
> for every plan row that maps to a page region, populate
> `visual_assertions:` with the selector → must_include_classes pairs the
> Visual Contract specifies. Initialize `visual_state` to `missing`.
> Functional `state` and `visual_state` are tracked independently.

### Grader system prompt update

Add a new rule (companion to the fuzzy-path-matching rule already in
place):

> For every row with `visual_assertions:`, examine the implementation
> files in the diff (`*.html.heex`, `*.ex` LiveView modules) and confirm
> the asserted classes appear at the asserted selectors. If they do,
> `visual_state: done`. If some selectors are present but missing
> classes, `visual_state: partial`. If the selector or classes are
> absent entirely, `visual_state: missing`. The verdict logic becomes:
> `approve` only when every row is `state: done` AND `visual_state: done`
> (or `nil` for rows with no visual_assertions).

### Grader evidence summary update

When building the user prompt, include a new section "## Test
assertions" that greps the LV test files for `assert_classes/3` calls
and shows them. The Grader can match these against the Visual Contract
selectors directly.

### Tester sub-agent update (`workflow/stages/03-test.md`)

After Step 3 (walk every Contract row), add:

> ### Step 3.5: Visual Contract verification
>
> For each Visual Contract row:
>
> 1. In the running browser, query the selector
>    (`document.querySelector("...")`).
> 2. Read its `classList` and confirm every `must_include` class is
>    present.
> 3. At each documented responsive breakpoint, resize the browser
>    (`page.setViewportSize(...)`) and re-check the selector.
> 4. Diff copy (heading, button label, placeholder, flash) against the
>    Visual Contract's "Copy parity" section character-by-character.
>
> Mark each Visual Contract row in the Tester Report as
> `✅ visual-verified`, `⚠ visual-drift (specify)`, or `❌ visual-missing`.
> A `⚠` or `❌` row → REQUEST_CHANGES.

## Order of execution

1. **Phase 1 — Foundation in gf_procurement** (manual PR or one
   Symphony dispatch):
   - Land `docs/lv-migration/VISUAL_CONTRACT.md` template
   - Land `test/gf_web/live/visual_helpers.ex`
   - Update `docs/lv-migration/{README,WORKER_PROMPT,TESTER_PROMPT}.md`
2. **Phase 2 — Symphony plumbing** (this branch, this session):
   - Update Planner system prompt for visual_assertions
   - Update Grader system prompt + evidence section
   - Update PromptBuilder.render_rows_md to surface visual_assertions
     in the row markdown the worker sees
   - Update `workflow/stages/03-test.md` (Step 3.5)
3. **Phase 3 — Backfill Wave 4** (Symphony dispatches):
   - Worker fills `VISUAL_CONTRACT.md` sidecar for each maintenance
     page (10 pages)
   - Worker adds `assert_classes/3` calls to existing maintenance LV
     tests
   - Symphony's next dispatch sees visual_assertions in the plan,
     Grader evaluates them, request_changes loops as needed
4. **Phase 4 — Forward to Wave 5+**: Wave-N issues created with the
   Visual Contract requirement baked in from day one. Process docs
   already in place. Workers fill it during Step 2 of every page.

## What we're NOT doing

- No automated screenshot comparison for now. Tier 3 is a follow-up
  once the Tier 1 + 2 baseline is stable.
- No image upload to a third-party visual-regression service. Pixel
  comparisons would happen locally via `pixelmatch` if/when added.
- No new Ecto table — `visual_assertions` and `visual_state` are
  JSON-only fields on existing `plans.plan_json`.

## Why this works for "later phases"

Wave 5+ get the discipline for free: process docs already there, the
Planner generates visual rows by default, the Grader enforces both
functional and visual `done`, the Tester walks responsive breakpoints.
The cost is one VISUAL_CONTRACT.md fill per page during the worker's
Step 2 — same place they're already filling the Page Contract. No new
phase, no new orchestrator path.
