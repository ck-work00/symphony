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

## Interactive agent takeover
Investigate whether a running agent session can be converted to interactive mode so the user can communicate with the agent and direct its activities. Currently agents run autonomously — the user can only watch. If the user sees an agent going off-track or wants to steer it, there's no way to intervene without killing the session and starting over.

Questions to answer:
- Can the Claude CLI accept user input mid-session while an agent is running?
- Could we inject messages into the conversation via the API (Anthropic or Claude Code)?
- Would a tmux-based approach work — attach to the session and type directly?
- What happens to the orchestrator's tracking if the user sends messages the orchestrator didn't initiate?
- Should this be a "pause and hand off" model (orchestrator stops, user takes over) or a "co-pilot" model (orchestrator and user both send messages)?

## Show issue title on dashboard
The dashboard only shows issue identifiers (e.g. GEA-2631). Show the issue title alongside it so the operator can tell at a glance what each agent is working on without clicking through to Linear.

## Dashboard polling overhead
When the dashboard LiveView is open, it polls `run_events` every second per expanded timeline. This hammers the SQLite DB with redundant queries. Should debounce or only poll when timeline is expanded.

## Orchestrator snapshot timeouts ("Snapshot unavailable")
The dashboard and TUI fetch status via `Orchestrator.snapshot()` → `GenServer.call(:snapshot, 15_000)`. The `:snapshot` handler is trivial (it just reads state), but the orchestrator is a single GenServer that runs its **entire poll cycle in-process**: Linear HTTP (`Tracker.fetch_candidate_issues` / `fetch_issue_states`), plan generation (`Planning.Workflow.assess` — one LLM call), and dispatch grading (`maybe_grade_plan_dispatch` — another LLM call). A GenServer handles one message at a time, so while a poll cycle is blocked on a slow LLM grade/plan (routinely >15s, worse under churn), the `:snapshot` call sits in the mailbox until it times out → `snapshot_payload` returns `:error` → "Snapshot unavailable / Snapshot timed out". Intermittent — only fires when a refresh lands during a slow cycle.

Fix:
- Proper: move the blocking poll-cycle work (LLM grade/plan, Linear calls, worker dispatch) into supervised `Task`s so the GenServer stays responsive to `:snapshot` and the other status/control calls.
- Cheap interim: raise the snapshot timeout above the worst-case grade time, and/or render the **last-known** snapshot on timeout (the dashboard already tracks `last_snapshot_fingerprint`) instead of erroring — shows slightly-stale status rather than "unavailable".

## Add OpenCode as an alternative agent backend
Symphony's agent layer is already abstracted behind `Config.agent_runner_module()` (claude → `Claude.AgentRunner`, default → legacy Codex runner). Adding sst/opencode as a third backend is mostly mirroring the Claude modules.

Why bother:
- Lets users run Symphony against models other than Anthropic's (opencode supports Anthropic, OpenAI, OpenRouter, Ollama, etc. via provider/model)
- Removes vendor lock-in for the harness
- opencode is open-source and self-hostable

What's needed:
- `lib/symphony_elixir/opencode/cli.ex` — port spawn, PTY wrapper, NDJSON line streaming. `claude/cli.ex` is the template; flag mapping below.
- `lib/symphony_elixir/opencode/stream_parser.ex` — map opencode events (`tool_use`, `step_start`, `step_finish`, `text`, `reasoning`, `error`) to Symphony's internal event shape (`:session_started`, `:assistant`, `:tool_use`, `:tool_result`, `:result`). `sessionID` is on every line so session-id extraction is simpler than Claude's.
- `lib/symphony_elixir/opencode/agent_runner.ex` — turn loop. Almost a copy of `claude/agent_runner.ex` with the CLI alias swapped.
- Config keys in `config.ex`: `opencode_command`, `opencode_model`, `opencode_turn_timeout_ms`, `opencode_stall_timeout_ms`, `opencode_dangerously_skip_permissions?`. Add an `"opencode" -> SymphonyElixir.OpenCode.AgentRunner` branch in `agent_runner_module/0`.
- WORKFLOW.md: optional `agent.backend: opencode` and `opencode:` block.

Flag mapping (Claude → opencode):
- `claude -p <prompt>` → `opencode run <prompt>`
- `--output-format stream-json` → `--format json`
- `--resume <id>` → `--session <id>`
- `--dangerously-skip-permissions` → same flag, same semantics

Real friction points to handle:
- **Tool restriction is not a CLI flag.** Claude takes `--tools Agent,Bash,Edit,...` per invocation. opencode bakes permissions into named agents (`opencode agent create --permissions bash,read,edit,...`). Setup story: provision a `symphony-worker` agent during slot setup, pass `--agent symphony-worker` per run. This means slot-claim.sh (or first-time setup) needs to create the agent. No equivalent to `--tools ""` for "no tools" — must enumerate.
- **MCP isolation is config-file driven, not per-invocation.** Claude's `--strict-mcp-config --mcp-config '{}'` makes MCP servers vanish for the run. opencode honors whatever's in `~/.config/opencode/`. To match Symphony's current isolation, run opencode with a sandboxed config dir (e.g. `OPENCODE_CONFIG_DIR=/tmp/symphony-opencode-empty`) so user-level MCP servers don't bleed in. Verify the env var is honored before relying on it.
- **Token usage is not in the JSON stream.** Claude emits `usage: { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens }` on the `result` event. opencode's `run.ts` JSON emitter (sst/opencode v1.14) only writes `tool_use` / `step_start` / `step_finish` / `text` / `reasoning` / `error` — no usage. Symphony's per-run token accounting and the `codex_totals` rollup will go to zero for opencode runs unless we query the session via opencode's HTTP server (`opencode serve` + `/session/:id`) after the run completes. This is the biggest delta — all the others are flag/string remaps.
- **Phase inference table.** `StreamParser.infer_phase_from_tools` maps Claude's PascalCase tool names (`Read`, `Edit`, `Bash`) to phases. opencode uses lowercase (`read`, `edit`, `bash`). One-line change per mapping.

Estimate: ~500–700 lines of new code, no orchestrator changes, side-by-side via config. Half a day to wire and smoke-test against a low-stakes issue. Another half-day to add HTTP-based token accounting and verify MCP isolation.

References:
- sst/opencode run.ts: https://github.com/sst/opencode/blob/main/packages/opencode/src/cli/cmd/run.ts
- CLI docs: https://opencode.ai/docs/cli/
- Headless --resume status (closed, implemented): https://github.com/sst/opencode/issues/2404
- Stream JSON output (closed, implemented): https://github.com/sst/opencode/issues/2449
