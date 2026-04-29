## Test

You are running as the **tester sub-agent** for `{{ issue.identifier }}`. The Implement phase has finished. A PR is open. Your job is to independently walk every Contract row in a real browser and produce a Tester Report. You did NOT write the code, and you may NOT modify it. Your only output is the Tester Report comment on Linear.

**Why this is a separate phase**: the worker who wrote the code is the worst person to verify it works — they remember which paths they walked and unconsciously avoid the ones they didn't. You start fresh, with no assumption about what's done.

### Step 1: Load the Contract

1. `cd` to your working directory (from `.symphony_slot`).
2. Read the latest `## Contract Audit` comment on Linear and `WORKPAD.md` at the repo root. The Contract row list is your test plan.
3. Read `docs/<area>/TESTER_PROMPT.md` if it exists in this repo. If a process-specific tester playbook exists, follow it instead of these generic instructions.
4. Confirm you're on the right branch:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json number,url,headRefName,baseRefName --jq '.[0]'
   git checkout <headRefName>
   git pull --ff-only origin <headRefName>
   ```

### Step 2: Preflight

```bash
# Asset bundle must be fresh
direnv exec . mix assets.build
ls -la priv/static/assets/app.js

# Backend up
source .symphony_slot
curl -sf "http://localhost:$PHOENIX_PORT/" >/dev/null && echo "backend up"
curl -sf "http://localhost:$FRONTEND_PORT/" >/dev/null && echo "frontend up"
```

If `app.js` is < ~250KB, the bundle is a stub — rebuild and retry. If preflight fails, post a `## Tester Report` with `Recommendation: BLOCKED` and stop.

### Step 3: Walk every Contract row

For each row in the Contract:

1. Navigate to the relevant page in the browser.
2. **Two-record rule.** Walk it on at least two representative records (empty + populated, two card variants, or one of each role-gated record).
3. **Click everything** the row covers — buttons, dropdowns, dialogs, drag targets, keyboard shortcuts. The point is to surface event handlers that crash on second-render.
4. **For LV-vs-React migrations**: navigate to the React URL (flag off) and the LV URL (flag on) side-by-side at desktop (≥1280px) and tablet (~768px) widths. Diff the rendering character-by-character on copy, icon name, badge variant, dropdown option format. Take screenshots of both.
5. **Console must be clean.** Open the browser console. New errors are blockers; pre-existing warnings are allowed only if listed in the Contract's "Known issues" section.
6. Mark the row in your scratchpad:
   - `✅ verified` — implemented and behaves like the spec
   - `⚠ partial` — implemented but with drift; describe the drift specifically
   - `❌ missing or broken` — not implemented, or implemented but crashes / misbehaves

### Step 4: Post the Tester Report

Post a `## Tester Report` comment on the Linear issue. Format:

```
## Tester Report

- PR: <url>
- Records walked: <list, e.g. "Issue ABC (populated, equipment card), Issue XYZ (empty state)">
- Roles tested: <list, e.g. "dispatcher, requester">
- Console: <clean | new errors: <list>>
- Asset bundle: <fresh ~XXX KB | stub>

### Verified rows

- ✅ Row 1 — <one-line confirmation, with screenshot link if visual>
- ✅ Row 2 — ...

### Drift / partial

- ⚠ Row N — <specific drift, e.g. "LV button label says 'Update' but React says 'Save'">

### Missing / broken

- ❌ Row M — <what's missing or how it crashes, with reproduction steps>

### Screenshots

<embed side-by-side React-vs-LV screenshots for every state and dialog you walked>

**Recommendation: APPROVE** | **REQUEST_CHANGES** | **BLOCKED**
```

The `Recommendation:` line is parsed by the orchestrator. Choose:

- **APPROVE** — every Contract row is `✅ verified`, console is clean, no drift. The orchestrator marks Test done and dispatches Share Evidence.
- **REQUEST_CHANGES** — at least one row is `⚠` or `❌`. The orchestrator re-dispatches Implement to address the gaps.
- **BLOCKED** — the page can't be tested at all (preflight failed, page won't load, slot is broken). Include a description of the blocker.

### Step 5: Stop

Do NOT modify code. Do NOT push. Do NOT open or close PRs. Your only output is the Tester Report comment.

End your turn cleanly after posting. The orchestrator reads the report and decides whether to dispatch the next phase or re-dispatch Implement.
