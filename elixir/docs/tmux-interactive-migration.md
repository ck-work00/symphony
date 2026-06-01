# Tmux Interactive Migration

## Background

Anthropic is splitting Claude Code billing into two pools:

- **Interactive use** (terminal, IDE, claude.ai) — counts against the existing plan limit
- **Programmatic use** (`claude -p`, GitHub Actions, third-party agents, the Agent SDK) — moves to a separate per-user monthly credit pool

Symphony currently invokes Claude via `claude -p <prompt> --output-format stream-json` for every turn. Under the new billing, every agent run draws from the smaller programmatic credit pool. Moving Symphony to **interactive mode** (long-running `claude` in a tmux session, prompts delivered via `tmux paste-buffer`) keeps Symphony on the standard plan.

## Goals

1. Stop using `claude -p` for agent execution.
2. Preserve full observability — token usage, phase detection, PR URLs, SYMPHONY_NEEDS_HELP — that today comes from stream-json events.
3. Keep the orchestrator, workspace/slot management, Linear integration, and phase judge untouched.
4. Survive crashes — if a tmux session dies, recover the conversation. *(Deferred: v1 fails the run cleanly on a dead session and lets the orchestrator re-dispatch. `--resume` recovery comes later.)*

## Decisions (resolved)

- **Host:** tmux (`paste-buffer` reliability + session survives a BEAM crash).
- **Rollout:** hard cutover — replace `Claude.CLI`, no dual-backend config switch.
- **Crash recovery:** deferred — `alive?` check before each prompt; on a dead session, fail the run and let the orchestrator re-dispatch.
- **Billing premise:** confirmed — a long-running interactive `claude` bills against the plan, not the programmatic credit pool.

## Verified facts (against Claude Code 2.1.159 + real session JSONL)

- `--session-id <uuid>` exists and pre-assigns the session — we own the id, no longer extract it from the stream.
- `end_turn` appears reliably on the final assistant message of a completed turn.
- Per-turn `usage` lives under `message.usage` with full cache breakdown — exactly what `StreamParser.nested_message_usage/1` already reads.
- JSONL top-level keys are camelCase (`sessionId`, `parentUuid`, `cwd`, `gitBranch`) — **not** `session_id`.
- Subagent (`Agent` tool) turns land in the same JSONL with `isSidechain: true` and their own `end_turn`.
- There is **no** `{"type":"result"}` event in interactive mode (that is `--print`-only).

## Current Architecture (for reference)

```
Orchestrator
  └── Claude.AgentRunner.run(issue)
        └── loop up to max_turns:
              ClaudeCLI.run(prompt, workspace)        # first turn
                or
              ClaudeCLI.resume(session_id, prompt, …) # later turns
                └── Port.open → /bin/sh -c "script -q /dev/null claude -p …"
                      └── stream-json events on stdout
                            └── StreamParser → on_event → {:codex_worker_update, …}
              # between turns:
              check git progress, fetch Linear comments, ask PhaseJudge
```

Per turn: spawn-run-exit. Sessions are continued with `--resume <session_id>`. The Erlang port wraps Claude under `script` to force line-buffered stdout so stream-json events arrive promptly.

## Target Architecture

```
Orchestrator                                       (unchanged)
  └── Claude.AgentRunner.run(issue)               (modified)
        ├── TmuxCLI.start_session(workspace, session_id)
        │     # tmux new-session + claude --session-id <uuid> --dangerously-skip-permissions …
        ├── SessionWatcher.start(jsonl_path, on_event)
        │     # tails ~/.claude/projects/<escaped-cwd>/<session-id>.jsonl
        ├── loop up to max_turns:
        │     TmuxCLI.send_prompt(session, prompt)
        │           # write prompt to temp file
        │           # tmux load-buffer + paste-buffer + Enter
        │     SessionWatcher.wait_for_turn(timeout)
        │           # blocks until assistant message with stop_reason
        │     # between turns: check git progress, Linear comments, PhaseJudge
        └── TmuxCLI.stop_session(session)         # /exit + kill-session
```

The key insight: **Claude Code writes the full structured event stream to a JSONL file even in interactive mode**. That file is our event source instead of stdout. Every event we get from stream-json — including `usage` with cache breakdowns, tool use, message text, stop reasons — is in the JSONL.

## Module Changes

### New: `SymphonyElixir.Claude.TmuxCLI`

Replaces `SymphonyElixir.Claude.CLI`.

```elixir
@spec start_session(Path.t(), String.t(), keyword()) :: {:ok, session_handle()} | {:error, term()}
def start_session(workspace, session_id, opts)
# 1. session_name = "symphony-#{session_id}"
# 2. tmux new-session -d -s session_name -x 200 -y 50 -c workspace
# 3. sleep 2 (let tmux settle)
# 4. tmux send-keys "unset CLAUDECODE && claude --session-id #{session_id} \
#       --dangerously-skip-permissions --tools Agent,Bash,Edit,Read,Write,Glob,Grep \
#       --mcp-config '{\"mcpServers\":{}}' --strict-mcp-config" Enter
# 5. wait_for_ready (poll capture-pane for the ❯ prompt)

@spec send_prompt(session_handle(), String.t()) :: :ok | {:error, term()}
def send_prompt(session, prompt)
# 1. write prompt to /tmp/symphony-#{session_id}-#{turn}.txt
# 2. tmux load-buffer /tmp/symphony-#{session_id}-#{turn}.txt
# 3. tmux paste-buffer -t session_name
# 4. tmux send-keys -t session_name Enter
# load-buffer/paste-buffer is atomic and reliable for any prompt size,
# unlike character-by-character send-keys

@spec stop_session(session_handle()) :: :ok
def stop_session(session)
# 1. tmux send-keys -t session_name "/exit" Enter
# 2. sleep 2
# 3. tmux kill-session -t session_name (idempotent)
# 4. rm /tmp/symphony-#{session_id}-*.txt

@spec alive?(session_handle()) :: boolean()
# tmux has-session -t session_name

@spec session_jsonl_path(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
def session_jsonl_path(session_id)
# Do NOT compute the escaped project dir — the escaping rule is more than /→-
# (underscores also become dashes; see "JSONL Path Derivation"). Since we own
# the session_id, locate the file by its unique name instead:
#   find ~/.claude/projects -name "<session_id>.jsonl"
# Poll until it appears (Claude writes it on first turn).
```

Launch uses `--dangerously-skip-permissions`, which also bypasses the per-directory
"Do you trust the files in this folder?" prompt on a fresh workspace clone — verify
this on a never-before-seen workspace dir before cutover, since that prompt would
otherwise hang `wait_for_ready`.

No more `Port.open`, no PTY wrapper, no process group management.

### New: `SymphonyElixir.Claude.SessionWatcher`

A GenServer that tails the session JSONL file and emits parsed events.

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
# opts: :jsonl_path, :on_event (fn), :name

# Internally:
#   - opens the file with File.open + :read mode (or polls if not yet created)
#   - tracks byte offset; reads new bytes on each tick
#   - splits on \n, parses each line with StreamParser.parse_line/1
#   - calls on_event.(event) for each parsed event
#   - exposes wait_for_turn/2 to block until the next turn completes

@spec wait_for_turn(GenServer.server(), timeout()) :: {:ok, turn_summary()} | {:error, term()}
# Returns when we see a MAIN-CHAIN assistant message (isSidechain != true) with
# stop_reason "end_turn" (or "stop_sequence") appearing after the byte offset we
# recorded at send_prompt time. turn_summary includes that message's usage.
```

**Sidechain filtering (required).** The allowed tools include `Agent`. When the
agent spawns a subagent, the subagent's messages land in the same JSONL with
`isSidechain: true` and their own `end_turn`. Without filtering, `wait_for_turn`
fires early on a subagent's completion mid-turn. Count only `isSidechain != true`.

**Boundary by byte offset, not user UUID.** We paste the prompt via tmux; Claude
generates the `user` entry's UUID, so we can't know it at send time. Instead record
the JSONL file size before pasting and treat the first qualifying `end_turn` after
that offset as the boundary.

**Tailing strategy**: poll-based with a 250 ms interval. The JSONL file is append-only; reading new bytes and splitting on newlines is robust. If a partial line is in the buffer (write in progress), hold it until the next poll. Optional upgrade: use `:file_system` (fs_inotify on Linux, FSEvents on macOS) for change notifications.

**Turn boundary detection**:
- Each user prompt produces a `{"type":"user", …}` entry with a `uuid`.
- The model's response is a chain of `{"type":"assistant", …}` entries, each with `parentUuid` pointing back to the previous entry.
- The chain ends with an assistant message whose `stop_reason` is `"end_turn"` (no further tool use). That's the turn boundary.
- We record the user message UUID on `send_prompt` and watch for the matching `end_turn` assistant message.

### Modified: `SymphonyElixir.Claude.StreamParser`

Most extraction functions (`extract_usage`, `extract_phase`, `extract_pr_url`, `extract_needs_help`, `extract_screenshot_urls`) work on JSONL events unchanged — usage is nested under `message.usage`, which `nested_message_usage/1` already handles. Two changes are required:

- **`extract_session_id/1`** must also match the camelCase `"sessionId"` key (JSONL uses `sessionId`, not `session_id`). In practice we own the id via `--session-id`, so the dashboard can be fed the known UUID directly and this becomes belt-and-suspenders.
- **`extract_pr_url(%{event_type: :result})`** is dead in interactive mode — there is no `result` event. PR URL comes from assistant text / `tool_result` (already handled). Keep the clause, just don't depend on it. End-of-run usage totals must be summed from per-turn `end_turn` messages rather than read from a final `result`.

Cleanup (post-migration): the stream-only `result` handling and any `-p`-specific fields can be removed.

### Modified: `SymphonyElixir.Claude.AgentRunner`

```elixir
def run(issue, recipient, opts) do
  session_id = UUID.uuid4()
  {:ok, workspace} = Workspace.create_for_issue(issue)
  {:ok, session} = TmuxCLI.start_session(workspace, session_id, opts)
  {:ok, jsonl_path} = TmuxCLI.session_jsonl_path(session_id)  # find by unique filename
  {:ok, watcher} = SessionWatcher.start_link(
    jsonl_path: jsonl_path,
    on_event: claude_event_handler(recipient, issue)
  )

  try do
    run_turns(session, watcher, issue, recipient, opts, 1, nil)
  after
    SessionWatcher.stop(watcher)
    TmuxCLI.stop_session(session)
    Workspace.run_after_run_hook(workspace, issue)
  end
end

defp run_turns(session, watcher, issue, recipient, opts, turn, prev_user_uuid)
     when turn <= max_turns do
  prompt = build_prompt(issue, turn, opts)
  {:ok, user_uuid} = TmuxCLI.send_prompt(session, prompt)
  {:ok, turn_summary} = SessionWatcher.wait_for_turn(watcher, turn_timeout)

  progress = check_turn_progress(workspace)
  cond do
    no_progress?(progress, turn) and judge_says_done?(...) -> :ok
    not active_issue?(issue) -> :ok
    true -> run_turns(session, watcher, issue, recipient, opts, turn + 1, user_uuid)
  end
end
```

The between-turn logic (Linear comment fetching, progress check, phase judge, no-progress counter) is **unchanged**. Only the turn execution mechanism changes.

### Config additions

```elixir
# config/runtime.exs
config :symphony_elixir, SymphonyElixir.Claude.TmuxCLI,
  session_prefix: "symphony",
  tmux_width: 200,
  tmux_height: 50,
  startup_delay_ms: 2_000,
  ready_poll_interval_ms: 500,
  ready_timeout_ms: 30_000

config :symphony_elixir, SymphonyElixir.Claude.SessionWatcher,
  poll_interval_ms: 250,
  jsonl_base_path: "~/.claude/projects"
```

## JSONL Path Derivation

**Do not compute the project directory.** The escaping rule is not simply `/`→`-`.
Verified against the real install:

| Workspace path | Project directory |
|---|---|
| `/Users/ck/code/symphony` | `-Users-ck-code-symphony` |
| `/Users/ck/code/gf_procurement` | `-Users-ck-code-gf-procurement` *(underscore → dash!)* |

The rule is closer to `[^A-Za-z0-9-]` → `-` and may change between versions.
Since we assign `--session-id`, the JSONL filename is globally unique — locate it
by name instead of deriving the directory:

```elixir
def session_jsonl_path(session_id) do
  base = Path.expand("~/.claude/projects")

  case Path.wildcard(Path.join([base, "*", "#{session_id}.jsonl"])) do
    [path | _] -> {:ok, path}
    [] -> {:error, :not_found}
  end
end
```

Poll this after `start_session` until the file appears (Claude writes it on the
first turn). Fail loudly if it doesn't appear within `ready_timeout_ms`. This makes
the path-escaping risk row below obsolete.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| JSONL write buffering delays event delivery | Poll at 250 ms; verify behavior end-to-end. Worst case: drop to 100 ms or use `:file_system`. |
| Tmux session crashes mid-turn | v1: `TmuxCLI.alive?` check before each prompt; on a dead session, fail the run and let the orchestrator re-dispatch. `--resume <session_id>` recovery (JSONL persists, conversation intact) is deferred to a later pass. |
| Subagent (`Agent` tool) `end_turn` ends the turn early | Filter `isSidechain: true`; count only main-chain `end_turn` after the recorded byte offset. |
| Trust prompt on a fresh workspace hangs `wait_for_ready` | `--dangerously-skip-permissions` bypasses it; verify on a never-before-seen dir before cutover. |
| `paste-buffer` truncation for very long prompts | Test with 10–20 KB prompts; load-buffer is documented to handle arbitrary size, but verify. |
| Claude hits a permission prompt | Use `--dangerously-skip-permissions` (already in current setup). |
| Path-escaping rules change between Claude Code versions | Obsolete — we locate the JSONL by unique `<session_id>.jsonl` filename, not by deriving the escaped directory. See "JSONL Path Derivation". |
| Tmux session leaks if BEAM crashes | On startup, kill any orphaned `symphony-*` tmux sessions whose JSONL hasn't been touched in N minutes. |
| Slow turn completion detection | The `end_turn` stop_reason is reliable. If we miss it, the existing `stall_timeout_ms` and `turn_timeout_ms` watchdogs still apply. |
| Concurrent agents collide on tmux session names | Session name = `symphony-<session_id>` (UUID) — guaranteed unique. |

## Implementation Phases

1. **`Claude.TmuxCLI`** — session lifecycle, prompt delivery via load-buffer, alive check, `session_jsonl_path/1` (find-by-filename).
2. **`Claude.SessionWatcher`** — JSONL tailing GenServer, byte-offset turn-boundary detection with sidechain filtering, event emission.
3. **`StreamParser` tweaks** — match camelCase `sessionId`; stop depending on the (absent) `result` event for usage totals.
4. **`Claude.AgentRunner`** refactor — swap CLI calls for TmuxCLI + SessionWatcher; keep all between-turn logic (Linear comments, progress check, PhaseJudge, no-progress counter).
5. **Config + supervision** — add new config keys; supervise SessionWatcher under TaskSupervisor; orphan-session reaper for leaked `symphony-*` tmux sessions.
6. **End-to-end test** — run one real issue through the new path; compare dashboard output and token tracking against the old `-p` mode (captured before cutover).
7. **Hard cutover** — delete `Claude.CLI`, point `AgentRunner` at the tmux path. No dual-backend switch.

## Resolved

- Host: tmux. Rollout: hard cutover. Crash recovery: deferred. Billing premise: confirmed. (See "Decisions" near the top.)
- `--session-id` confirmed present in Claude Code 2.1.159.

## Phase 1 — built and validated (`Claude.TmuxCLI`)

`SymphonyElixir.Claude.TmuxCLI` is implemented and proven end-to-end against
Claude Code 2.1.159 on a **fresh, untrusted** workspace: start → multi-turn
prompts → JSONL discovery → usage extraction → clean teardown, no leftover tmux
sessions or temp files. Config keys live under `:claude` (`tmux_*`).

Findings that shaped the implementation:

- **The trust dialog is NOT bypassed by `--dangerously-skip-permissions`.** On a
  fresh workspace clone Claude shows "Do you trust the files in this folder?".
  `wait_for_ready` detects it and auto-answers (the workspace is always our own
  fresh clone). Resolves the open item — the answer is "no, it doesn't bypass".
- **Readiness signal:** the `❯` marker alone is a false positive — it also appears
  as the selection cursor inside the trust dialog. We require the footer token
  counter (`<n> tokens`), which no modal shows, plus `❯`.
- **Paste must settle before Enter.** An Enter in the same render frame as the
  paste is dropped (submits nothing). `tmux_paste_settle_ms` (default 700 ms)
  gaps them.
- **Paste delivery is verified, then submitted.** After paste we confirm it
  landed in the input box before sending Enter, retrying the paste otherwise.
  Verification accepts either a literal prompt prefix (short prompts) OR a
  `[Pasted text #N]` placeholder (Claude collapses large pastes into these).
- **Large prompts work.** A 15 KB prompt submits intact in one attempt (verified
  by echoing a token placed at the very end). Resolves the open item.
- **`capture-pane -p` right-pads with blank lines** — strip trailing blanks before
  taking the input-box tail, or the tail is all padding.

## Phase 2 — built and validated (`Claude.SessionWatcher`)

`SymphonyElixir.Claude.SessionWatcher` is implemented and proven live: a tool-using
turn (echo + reply) plus a plain turn streamed through `on_event` (system,
assistant, tool_result events) and `wait_for_turn/2` returned turn 1 then turn 2
with correct usage — completing only at the main-chain `end_turn`, never at the
intermediate `tool_use`. 7 unit tests cover turn detection, sidechain filtering,
partial-line buffering, multi-turn sequencing, and timeout. Config: poll cadence is
`:claude` → `tmux_jsonl_poll_interval_ms` (default 250 ms).

Turn detection counts main-chain (`isSidechain` != true) assistant `end_turn`
messages in order; the Nth `end_turn` is turn N. `wait_for_turn/2` blocks for the
next turn in sequence and the watcher enforces the timeout itself (replies
`{:error, :timeout}`), so no caller leaks.

**Integration ordering for Phase 3 (AgentRunner):** the JSONL does not exist until
the first turn runs, and `session_jsonl_path/1` finds it by filename — so the order
is: `start_session` → `send_prompt(turn 1)` → `await_jsonl` → start
`SessionWatcher` on that path (it reads from offset 0, replaying turn 1's events) →
`wait_for_turn(1)` → loop. The watcher tolerates a not-yet-existing path (reads
empty), but discovery still needs the file, so the first prompt comes first.

## Phase 3 — built and validated (`StreamParser` + `AgentRunner`)

- `StreamParser.extract_session_id/1` now also matches camelCase `sessionId`.
- `AgentRunner` drives one long-lived session: `start_session` → per turn
  `send_prompt` + `SessionWatcher.wait_for_turn` → between-turn checks → send
  next. All between-turn logic (comments, progress, PhaseJudge, no-progress,
  issue-state, max_turns) is unchanged. Session/watcher torn down in `after`
  blocks; a failed turn/send raises (recovery deferred).
- Collaborators (`session_module` / `watcher_module`) are injectable; 4 unit
  tests cover max-turns stop, terminal-state stop, turn-timeout raise+teardown,
  start_session failure. `Claude.CLI` is now dead code, kept until phase-7 cutover.

## Phase 4 — built and validated (supervision + reaper)

- `TmuxCLI.reap_orphan_sessions/1` kills tmux sessions matching the Symphony
  prefix and removes their prompt temp files; no-op with no tmux server.
  `Application.start/2` calls it on boot (guarded so it never blocks startup).
  A freshly booted BEAM owns no runs, so any `symphony-*` session is a leak from
  a crashed run. Assumes one orchestrator per host.
- SessionWatcher stays linked to its run Task (under `TaskSupervisor`) — a dead
  run already tears down its watcher, so no separate supervision is needed.
- 3 tmux-tagged tests; verified live that booting reaps a leaked session.

## Phase 5 — comparison done; two dashboard gaps found

Ran an identical trivial prompt through both paths and compared the observable
stream (events, usage, session id).

**Parity confirmed:** both paths surface the assistant message, a non-nil
`session_id` (the `sessionId` fix makes this work in interactive mode), and token
`usage`. Phase detection, PR-URL detection, and SYMPHONY_NEEDS_HELP all read
assistant/tool events that the watcher emits unchanged. Token totals are the same
order of magnitude (`-p` 16836 vs interactive 15594 on the sample).

**Gap 1 — `turn_count` never increments.** The orchestrator increments the
dashboard TURN counter only on `:session_started` events (a `system`/`init`
subtype). Interactive JSONL emits **no `init` event** (only `system`/`turn_duration`
at each turn end), so `turn_count_for_update` never fires. In `-p` mode each turn
was a fresh process that re-emitted `init`, so the counter advanced per turn.

**Gap 2 — token accounting semantics differ.** `compute_token_delta` treats each
event's usage as a monotonically increasing per-session cumulative total and sums
deltas. `-p` reported a per-turn `result` total; interactive reports per-assistant-
message usage where `input_tokens` re-counts the cached context each call. The
dashboard total still grows and displays, but it tracks roughly the final context
size rather than summed consumption.

**Other:** interactive has no terminal `result` event (expected); the user-prompt
JSONL entry is categorized `:tool_result` and metadata entries as `:unknown` —
cosmetic, no downstream effect.

Both gaps live in `orchestrator.ex` token/turn accounting that was shaped for the
`-p`/Codex event shapes. Candidate fixes: count turns from the watcher's
main-chain `end_turn` (or the `system`/`turn_duration` event) instead of
`:session_started`; and treat each turn's `end_turn` usage as that turn's total.
**Not yet implemented** — `orchestrator.ex` and `presenter.ex` have unrelated
uncommitted edits, so the accounting change should be coordinated with that work.

## Open Items

- Wire the two Phase-5 dashboard fixes into the orchestrator (turn count + token
  accounting), coordinated with the in-flight `orchestrator.ex`/`presenter.ex` edits.
- Real end-to-end run driving an actual Linear issue through the orchestrator
  (creates a branch/PR/Linear comments — needs explicit go-ahead + a test issue).
- Event delivery cadence to the dashboard — push every event, or coalesce.
- **Phase 7:** delete `Claude.CLI` and its config/usage.

### Pre-existing test failures (not from this work)
Timing-sensitive tests in `core_test`, `orchestrator_status_test`, `extensions_test`,
`workspace_and_config_test` fail nondeterministically on baseline. Separately,
`core_test` "in-repo WORKFLOW.md renders correctly" fails deterministically due to
the repo's uncommitted `WORKFLOW.md` edits (the `attempt #2` assertion) — confirmed
independent of the migration.
- `Ctrl-U` clears only one input line, not a whole multi-line paste. Harmless
  today (the improved verification means retries don't fire on the normal path,
  and startup-race retries hit an empty input), but if a true mid-paste retry ever
  accumulates text, switch the pre-paste clear to a full-input reset.
