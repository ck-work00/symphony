## Implement

This is the unified phase: investigate, design, write tests, implement, verify, ship. You run end-to-end in this dispatch — no separate "Investigate" handoff. The dispatch budget is generous (`agent.max_turns`); use it. Do not declare done until the acceptance criteria are met.

### Step 1: Set up and route

1. `cd` to your working directory (from `.symphony_slot`).
2. Fetch the latest refs:
   ```bash
   git fetch origin
   ```
3. Read `CLAUDE.md` (or `AGENTS.md`) in the working directory for project conventions.
4. **Read process docs.** If the issue body or any in-repo doc points to a process directory (e.g. `docs/lv-migration/`), read every file in that directory in full before writing code. See the preamble's "Process docs in the repo are normative" section.
5. Read any design notes committed to the WIP branch — check for `WORKPAD.md`, `DESIGN.md`, `NOTES.md`, or `{{ issue.identifier | downcase }}.md` at the repo root and read them in full.
6. **Determine the base branch.** Most issues branch off `origin/main`, but stacked-diff workflows (waves, sub-issues) branch off a parent branch.

   First, check `.symphony_slot` for a `BASE_BRANCH=` line — `slot-claim.sh` writes it there if `SYMPHONY_BASE_BRANCH` was set by the orchestrator:
   ```bash
   source .symphony_slot
   echo "BASE_BRANCH from slot: ${BASE_BRANCH:-main}"
   ```
   Then verify against the issue body. Look for any of: a `Wave branch:` line, a `Page branch:` line, a stacked-branch diagram (e.g. `└── gea-NNNN-...`), or explicit instructions like "cut from origin/<branch>" / "PR targets <branch>, not main". If the issue body specifies a base branch and it differs from `.symphony_slot`, the issue body wins — set `BASE_BRANCH` to that value:
   ```bash
   BASE_BRANCH="<the branch name from the issue body, or the slot value, or main>"
   git fetch origin "$BASE_BRANCH"
   ```
7. Check for an existing PR for this issue:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json number,url,state,headRefName,baseRefName --jq '.[]'
   ```
   If an open PR exists, verify its `baseRefName` matches `BASE_BRANCH`. If they don't match, the PR is mis-stacked — flag it in the status comment and DO NOT silently re-target it. Check out the PR's branch and rebase onto `origin/$BASE_BRANCH`:
   ```bash
   git checkout <headRefName> && git rebase "origin/$BASE_BRANCH"
   ```
8. If no PR exists, ensure your branch is rooted at `origin/$BASE_BRANCH`:
   ```bash
   git checkout {{ issue.branch_name }} 2>/dev/null || git checkout -b {{ issue.branch_name }} "origin/$BASE_BRANCH"
   git rebase "origin/$BASE_BRANCH"
   ```
   Verify the merge-base is correct:
   ```bash
   MERGE_BASE=$(git merge-base HEAD "origin/$BASE_BRANCH")
   BASE_TIP=$(git rev-parse "origin/$BASE_BRANCH")
   git merge-base --is-ancestor "$MERGE_BASE" "$BASE_TIP" || echo "WARNING: branch base is wrong"
   ```
   If the branch is rooted on the wrong base, fix it before continuing — wrong-base branches are the dominant cause of "PR opened but won't rebase cleanly."

### Step 2: Fill the Contract and post the audit

Find or build the Contract.

- **If a `PAGE_CONTRACT.md`-style filled Contract is already posted on Linear or committed to the branch**, that is your contract. Re-read it in full. Do not regenerate it.
- **If a Contract template exists in process docs** (e.g. `docs/<area>/PAGE_CONTRACT.md`), copy it and fill every section by reading the source code it describes (React tree, resolvers, schemas, hooks, dialogs — everything transitively). Filling the template is the verification that you read the code; an empty cell means you haven't opened the file yet. Post the filled Contract by editing the Linear issue body or as a comment.
- **If no template exists**, derive the row set from the issue body's `## Requirements`, `## Acceptance Criteria`, or prose. Each row should be specific enough to grade ✅ / ⚠ / ❌ later.

Then write `WORKPAD.md` at the repo root as your local audit ledger:

```markdown
# {{ issue.identifier }} — Contract Audit

## Contract source
- <link to the filled Contract: Linear comment URL, or path to the in-repo doc>

## Rows

- ❌ Row 1 — <description>
- ⚠ Row 2 — <description> (partial: <what's done, what's missing>)
- ✅ Row 3 — <description>

## Deferrals (reviewer-approved only)

<none, OR a list with a link to the reviewer's signoff for each item>

## Status

- (in progress) <what you're working on this turn>
- (next) <what you'll pick up next turn>
```

Status legend:
- `❌` — not started or fully missing
- `⚠` — partial; describe what's done and what's left
- `✅` — implemented, tested, in the diff

Commit `WORKPAD.md` as your first commit on the branch:
```bash
git add WORKPAD.md && git commit -m "{{ issue.identifier }}: contract audit"
```

This makes the audit durable across dispatches. Future runs re-read it and pick up the next `❌` or `⚠` row. Also post the same audit content as a `## Contract Audit` comment on the Linear issue so reviewers can see progress without checking out the branch.

### Step 3: Close rows one at a time

Work the audit row by row. **One commit closes one (or a small batch of related) Contract rows.** Drive-by changes that aren't on the audit are not allowed.

For each `❌` or `⚠` row, in priority order (the Contract usually orders rows by importance):

1. **For backend (Elixir) work — write the failing test first.**
   - Write a test that asserts the expected behavior in the conventional `test/` location.
   - Run it and confirm it fails: `direnv exec . mix test <test_file>`.
   - Then implement to make it pass.
   - Run the test again to confirm.
2. **For frontend / LiveView work** — implement the change, then run a quick browser interaction in Step 6's preflight to verify it works. Frontend changes don't always need unit tests, but role-gated UI and shared components do.
3. **Update `WORKPAD.md`**: flip the row from `❌` to `⚠` (partial) or `✅` (done). If `⚠`, document what's still missing. Re-post the audit comment on Linear if the row state changed materially.
4. **Commit** with a message that names the row(s) closed: `{{ issue.identifier }}: <row description>`.

After every two or three rows, run the full backend suite to catch regressions:
```bash
direnv exec . mix test
direnv exec . mix check
direnv exec . mix format
```

### Step 4: Mid-run audit refresh

After you believe you've closed every row, BEFORE moving to verification, do this audit refresh explicitly:

1. Re-read the issue body, the filled Contract, and any design notes (don't trust your memory from Step 2).
2. Re-read every section of the Contract and your `WORKPAD.md`.
3. For every `✅` row: confirm there is a test (or a browser-verified interaction) that exercises it AND production code that satisfies it. List the file paths in your scratchpad.
4. For every `⚠` row: either upgrade it to `✅` by closing the gap, or downgrade to `❌` if you realize you haven't actually started.
5. For every `❌` row: implement it now. Do not promote it to a deferral on your own — see the preamble's no-unilateral-deferrals rule.
6. **Look for rows that aren't on your audit.** Contracts often have prose requirements that didn't make it into the row list, especially when the source doc was hand-edited. Re-scan the issue body and the Contract source for any requirements you missed.

Do not skip this step. The orchestrator will not catch missed rows — you will.

### Step 5: Static analysis and the full test suite

```bash
direnv exec . mix check
direnv exec . mix test
direnv exec . mix format
```

All checks must be green. If `mix check` flags anything, fix it. If a pre-existing test fails because of your changes, fix it. If a pre-existing test was already failing on `origin/main`, note it in your PR description and skip it; do not delete or rewrite tests to avoid them.

### Step 6: Browser preflight, then walkthrough

For any change that touches the frontend, a LiveView, or a user-facing flow, the browser walkthrough has three preflights and three rules. Skipping any of them is the single most common cause of "works on initial render, broken on every event" failures.

**Preflight 1: asset bundle is fresh.**
```bash
direnv exec . mix assets.build
ls -la priv/static/assets/app.js
```
Confirm `app.js` is at least ~250KB. A stub bundle (≤ a few KB) is the dominant cause of "page renders but client-side behavior is dead." The dev watcher's first build after a fresh slot start can leave the bundle in a stub state.

**Preflight 2: typecheck and static analysis.**
```bash
direnv exec . mix check
# If frontend changes:
cd frontend && tsc -b && cd ..
```
Both must be clean before browser verification.

**Preflight 3: server is responding.**
```bash
source .symphony_slot
curl -sf "http://localhost:$PHOENIX_PORT/" >/dev/null && echo "backend up"
curl -sf "http://localhost:$FRONTEND_PORT/" >/dev/null && echo "frontend up"
```

Then the walkthrough:

1. Log in as `$(whoami)+dispatcher@gearflow.com` with password `Test1234!`.
2. **Two-record rule.** Walk every page on at least **two representative records**: empty + populated, OR two card variants (e.g. equipment-card + maintenance-card on `/issues/:id/requests`), OR one of each role-gated record. One record proves nothing — many failure modes only show up on the second.
3. **Click everything.** Every button, dropdown, dialog open + cancel + submit, drag target, keyboard shortcut. A LiveView can render correct initial HTML while crashing on every subsequent event because of one missing `phx-click` handler. Without clicking, you don't know.
4. **Console must be clean.** Open the browser console. Pre-existing warnings are allowed only if explicitly listed in the Contract's "Known issues" section. New errors are blockers.
5. Take side-by-side screenshots: the React URL (flag off) and the LV URL (flag on), at desktop (≥1280px) and tablet (~768px) widths. Save them as `screenshot-<page>-<state>-<width>.png`.
6. If role restrictions apply, repeat the walkthrough with the relevant role accounts.

For backend-only changes (internal modules, contexts not exposed via the API), skip the browser walkthrough but say so explicitly in the PR description and explain why.

### Step 7: Commit, rebase, push, PR

1. Make sure all changes are committed with descriptive messages: `{{ issue.identifier }}: <row(s) closed>`. The first commit is `WORKPAD.md`; subsequent commits each close one or more Contract rows.
2. Rebase onto the base branch you determined in Step 1 — **not always `origin/main`**:
   ```bash
   git fetch origin "$BASE_BRANCH"
   git rebase "origin/$BASE_BRANCH"
   ```
   If there are conflicts, resolve them. If the rebase fails repeatedly, `git rebase --abort`, investigate the conflict, and try again.
3. Push:
   ```bash
   git push -u origin {{ issue.branch_name }}
   ```
   If push fails (non-fast-forward), inspect with `git log --oneline origin/{{ issue.branch_name }}..HEAD` and decide whether to force-with-lease (only after confirming you're not stomping on someone else's work):
   ```bash
   git push --force-with-lease origin {{ issue.branch_name }}
   ```
4. Create or update the PR. **Target the base branch, not `main`** unless the base IS main:
   ```bash
   # If no PR exists yet:
   gh pr create --base "$BASE_BRANCH" --title "{{ issue.identifier }}: <title>" \
     --body "$(cat <<'EOF'
   ## Summary
   <what this PR does, in 2-3 bullets>

   ## Contract Audit
   <copy the full audit from WORKPAD.md — every row with ✅ / ⚠ / ❌ status>

   ## Testing
   <what you tested — unit, integration, browser; list which records you walked, which interactive elements, what role accounts>

   ## Screenshots
   <embed side-by-side screenshots: React vs LV at desktop and tablet widths, for every state of every page>

   ## Deferrals
   <none, OR list with link to reviewer's signoff for each item>

   Linear: {{ issue.identifier }}
   EOF
   )"
   ```
5. Verify the PR was actually created:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json url --jq '.[0].url'
   ```
   If empty, retry. Do NOT declare done with branch pushed but no PR — that's the failure mode we're trying to eliminate.

### Step 8: Final audit refresh

Before ending the turn:

1. Confirm the PR URL exists and is open.
2. Confirm the PR's `baseRefName` matches the `BASE_BRANCH` you determined in Step 1.
3. Confirm CI has been triggered (`gh pr checks <pr-number>`).
4. Re-read your `WORKPAD.md`. Every row should be `✅` or have a documented reviewer-approved deferral. **No `⚠` or `❌` rows may remain unaddressed**; if any do, go back to Step 3 and close them.
5. Read the latest comments on the Linear issue. If there's an `@agent` instruction newer than your last commit, address it before ending.

### Step 9: Re-post the audit

Re-post the final audit on the Linear issue (replacing the in-progress one from Step 2). Include the Tester section if applicable — leave it empty if the Test phase hasn't run yet; the orchestrator will dispatch a tester sub-agent on the next phase.

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "{{ issue.id }}" --arg body "$AUDIT_BODY" '{
    query: "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }",
    variables: { id: $id, body: $body }
  }')"
```

Where `$AUDIT_BODY` is markdown like:

```
## Contract Audit

- PR: <url>
- Base branch: <BASE_BRANCH>
- CI: <pending|green|red>
- Rows: <X ✅ / Y ⚠ / Z ❌ / W deferred>

### Closed this turn

- ✅ Row N — <description, link to commit>

### Open

- ⚠ Row M — <description, what's still missing>
- ❌ Row P — <description, why it's still untouched>

### Deferrals (reviewer-approved only)

<none, OR list with reviewer signoff link>

### Screenshots

<embed side-by-side screenshots if applicable>
```

### Done

You have completed the unified Implement phase. Your deliverables are:

1. `WORKPAD.md` committed with the contract audit
2. Tests committed for every backend behavior change
3. Production code that makes those tests pass
4. `mix check` and `mix test` green
5. PR open against the correct base branch with CI triggered
6. Filled Contract included in the PR description
7. Audit comment posted/updated on Linear

If any of these is missing, you are not done. Continue working — do not end the turn.

Once Implement passes, the orchestrator dispatches the Test phase: a tester sub-agent walks every Contract row in a real browser and posts a Tester Report. If the Tester Report comes back as REQUEST_CHANGES, you'll be re-dispatched to Implement to address the gaps.
