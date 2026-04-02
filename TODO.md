# Symphony TODO

## Post-ship review gate
After a worker ships a PR, the orchestrator should poll CI and review status before marking the issue done. Currently the judge sees `pr_created: true` and moves on immediately — there's no time for CI to run or reviewers (CodeRabbit, humans) to post comments.

Needed:
- After Ship phase completes, enter a review-gate hold (e.g. 5 min)
- Poll CI status every ~60s until it resolves (passed/failed)
- Poll for new review comments (CodeRabbit takes 2-5 min)
- If CI fails or actionable review comments appear, retask the agent to fix
- Only mark done when CI passes and no unaddressed comments (or timeout)

## Surface blocked issues on the dashboard
Issues that hit `max_runs_per_issue` silently disappear from the dashboard — the orchestrator logs a warning but the user sees nothing. These issues still need work but something went wrong (infrastructure failures, stale locks, etc).

Needed:
- A "Blocked" section on the dashboard showing issues that hit max retries
- Show the reason (last error, run count, last outcome)
- A "Reset & Retry" button that clears the failed run history and re-dispatches
- This is the primary intervention point for users — they need to see it

Root causes to also fix:
- Failed slot claims (0-turn runs) count toward max_runs — they shouldn't
- Stale slot locks from crashed/killed runs are never cleaned up
- Consider a TTL on locks, a startup sweep, or orchestrator-level lock release on hook failure

## Detect issue description changes while agent is working
The orchestrator fetches the issue once at dispatch and never re-reads the description. If the user updates the issue (adds details, clarifies requirements, attaches screenshots) while the agent is working, the agent never sees the changes.

The agent runner already re-fetches issue *state* between turns (`continue_with_issue?`) and fetches new *comments* (`fetch_new_comments`). It should also detect description changes:

- Between turns, re-fetch the full issue (description included)
- Diff the description against what was originally dispatched
- If changed, inject a "The issue description was updated" notice into the continuation prompt with the new/changed content
- This lets users steer the agent mid-run by editing the issue

The `@agent` prefix convention for comments works for ad-hoc instructions. Description changes are for updating the source of truth.

## Evaluate test coverage quality, not just existence
The evaluator currently checks `tests_written: bool` — did any test file change. This doesn't catch agents that write one token test for a multi-file change. The judge should evaluate coverage adequacy:

- Compare test file count vs source file count (ratio)
- Check test line count relative to implementation line count
- Use the PR diff to identify untested code paths (functions added without corresponding test cases)
- Feed this back to the retask prompt: "You changed 5 source files but only wrote 1 test file. Add tests for X, Y, Z."

This would catch the GEA-2463 case where the agent wrote one test file for a large feature.

## Judge should detect unanswered help requests on Linear
When an agent posts a question or asks for help on the Linear issue, the judge should not dispatch the next phase until a human responds. Currently the orchestrator detects `SYMPHONY_NEEDS_HELP` in the output stream, but if the agent posts a question as a regular Linear comment, the judge ignores it and moves on.

Needed:
- After each phase, check Linear comments for unanswered agent questions (e.g. comments ending with `?` from the automation user with no subsequent human reply)
- If found, hold dispatch and surface on the dashboard as "Waiting for human input"
- Resume when a human replies (detected on next poll)
- The dashboard should show these prominently — this is another intervention point

## Investigate Share Evidence phase crashes (exit 143 SIGTERM / exit 1)
The Share Evidence phase consistently crashes with subprocess_exit:1 (context overflow) or subprocess_exit:143 (SIGTERM). Blocking Playwright MCP via --strict-mcp-config helped reduce context usage from 1M to 30-44K but agents still crash with SIGTERM.

Possible causes:
- The `before_run` hook runs the full slot claim script on every retry, which does `git reset`, `mix deps.get`, and `devenv-start.sh` — this may interfere with a running Claude process
- Two agents dispatched simultaneously may have their hooks interfere with each other
- The `safe_port_close` function sends `kill -- -$PID` (SIGTERM to process group) which may be triggered prematurely
- The orchestrator may not cleanly terminate previous runs before dispatching retries

## Completed Work view needs actionable detail
The Completed Work section on the dashboard shows badges but no useful information about what happened. When an agent fails, the operator needs to understand:

- What did the agent actually do? (files read, files changed, commands run)
- Where did it fail? (which tool call, what error)
- What was the last thing it tried to do?
- Did it make any progress? (commits, Linear comments posted)
- Was it a context issue, an API error, a code error, or a stuck loop?

The error column currently shows a truncated RuntimeError which is useless. Consider:
- An expandable detail panel per completed entry (like the timeline on running entries)
- A summary line: "Read 12 files, edited 3, ran mix test, failed on context overflow"
- Link to the session log if available
- Show the last tool call and its result

## Dashboard polling overhead
When the dashboard LiveView is open, it polls `run_events` every second per expanded timeline. This hammers the SQLite DB with redundant queries. Should debounce or only poll when timeline is expanded.
