Continuation guidance (turn {{turn_number}}/{{max_turns}}):

The previous turn completed normally, but the Linear issue is still in an active state.
Resume from the current workspace state — do not restart from scratch.
{{comments_section}}

## Step 1: Re-orient

1. `cd` to your working directory and confirm git state:
   ```bash
   git branch --show-current
   git log --oneline origin/main..HEAD | head
   git status --short
   ```
2. **Re-read `WORKPAD.md`** at the repo root in full. This is your audit. Every `⚠` or `❌` row is open work for this turn.
3. **Re-read the latest `## Contract Audit` comment on Linear** — this is the version reviewers see. If it diverges from `WORKPAD.md`, trust the file (it's the canonical version) and re-post the audit at the end of this turn.
4. **Re-read the issue body, the filled Contract (if posted), and any in-repo design docs** (`DESIGN.md`, `docs/<area>/*.md`). The issue body may have been updated by the human reviewer between dispatches.

## Step 2: Pick up the next row

Find the next open row in `WORKPAD.md`:

- Priority: `❌` (missing) before `⚠` (partial). Within each, top of the list first.
- If every row is `✅` or reviewer-approved deferred, you're done with Implement — go to Step 5 below.
- If a row is genuinely blocked by missing info, post a status comment naming the blocker and emit `SYMPHONY_NEEDS_HELP`. Do NOT silently defer.

Implement the row by following Step 3 of the Implement phase (write failing test → implement → verify → commit). Update the row status in `WORKPAD.md` from `❌`/`⚠` to `✅` (or to `⚠` with a precise description of what's still missing).

## Step 3: Address @agent feedback if any

Check the Linear issue for any `@agent` comments newer than your last commit:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "query { issue(id: \"{{issue_id}}\") { comments { nodes { body createdAt user { name } } } } }"}' \
  | python3 -c "import sys,json; [print(f'{c[\"user\"][\"name\"]}: {c[\"body\"]}') for c in json.load(sys.stdin)['data']['issue']['comments']['nodes'] if '@agent' in c['body'].lower()]"
```

`@agent` instructions take priority over the audit — implement them before continuing with the row queue. If the instruction marks a row as Out-of-scope, that's a reviewer-approved deferral; record it in `WORKPAD.md` with the comment URL and skip the row.

## Step 4: Push and update

After closing one or more rows:

1. Run `direnv exec . mix check` and `direnv exec . mix test`. Both must be green.
2. Rebase onto the base branch (the same `BASE_BRANCH` you used originally — re-derive from the issue body if you forgot it, do NOT default to `main` if the issue body says otherwise):
   ```bash
   git fetch origin "$BASE_BRANCH"
   git rebase "origin/$BASE_BRANCH"
   ```
3. Push (use `--force-with-lease` if the rebase rewrote shared commits):
   ```bash
   git push origin {{ issue.branch_name }}
   ```
4. Re-post the Contract Audit on Linear with the updated row counts.

## Step 5: When everything is closed

If every Contract row is `✅` or reviewer-approved deferred, AND the PR is open against the correct base, AND CI is green or running, AND the latest audit comment is on Linear:

1. **You are DONE.** End your turn cleanly with NO further action.
   - Do NOT post a "I'm done" comment.
   - Do NOT emit `SYMPHONY_NEEDS_HELP`.
   - Do NOT re-run tests, take more screenshots, or refresh status.
2. The orchestrator's PhaseJudge will see the PR + audit and either dispatch the Test phase (tester sub-agent walks the page) or mark the issue done.

## When to use SYMPHONY_NEEDS_HELP

Only emit this marker if you are BLOCKED by something you cannot resolve:
- Missing credentials or permissions
- A Contract row that requires backend / data / design that doesn't exist yet
- Infrastructure issues (broken tooling, missing dependencies)

"Waiting for human merge" is NOT a blocker. "PR ready and CI green" is NOT a blocker. "I'd prefer human input on this row" is NOT a blocker — pick the most reasonable interpretation, document the assumption in the PR description, and continue.
