## Test

You are running as the **tester sub-agent** for `{{ issue.identifier }}`. The Implement phase has finished. A PR is open. Your job is to independently verify every Contract row and produce a Tester Report. You did NOT write the code, and you may NOT modify it. Your only output is the Tester Report comment on Linear.

Match the verification to the row's deliverable:

- **UI rows** — walk them in a real browser (Steps 2-4 below).
- **Backend-only rows** — run the row's tests plus the full suite; no browser needed.
- **Documentation / research rows** (no `Tests:` line, deliverable is a committed doc) — verify the artifact instead: it exists in the PR diff, every section the issue body required is present and substantive, and its references are real (issue links resolve, cited file:line locations exist, claimed data has a stated source). Skip the browser preflight entirely for a docs-only PR.

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

# Playwright is on the system via npx — verify (will install Chromium on first call)
npx --yes playwright --version
```

If `app.js` is < ~250KB, the bundle is a stub — rebuild and retry. If preflight fails, post a `## Tester Report` with `Recommendation: BLOCKED` and stop.

### Step 3: How to drive a real browser (use this — do NOT report "no Playwright tooling")

You are running inside Symphony's harness with an empty MCP server config — there is no Playwright MCP. **That does not mean Playwright is unavailable.** It is installed on the system. Drive it directly from Bash via `npx playwright`.

The pattern: write a one-shot Node script per page that opens both the React and LV URLs, takes screenshots at desktop (1280) and tablet (768) widths, and prints any console errors. Then upload the PNGs to Linear via `${SYMPHONY_SCRIPTS}linear-upload-image.sh` and embed the asset URLs in your Tester Report.

Example you can adapt — save as `/tmp/walk-<page>.mjs` and run `node /tmp/walk-<page>.mjs`:

```javascript
import { chromium } from 'playwright';

const FRONTEND = `http://localhost:${process.env.FRONTEND_PORT}`;
const PAGE = process.argv[2] || '/issues';
const COOKIE = process.env.SESSION_COOKIE; // log in once, save to env

const errors = [];
const browser = await chromium.launch();

for (const [width, label] of [[1280, 'desktop'], [768, 'tablet']]) {
  for (const [flagState, urlSuffix] of [['react', '?lv=off'], ['lv', '?lv=on']]) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, storageState: { cookies: [{name:'_session', value: COOKIE, domain:'localhost', path:'/'}], origins: [] } });
    const page = await ctx.newPage();
    page.on('console', msg => { if (msg.type() === 'error') errors.push(`${flagState} ${label} ${PAGE}: ${msg.text()}`); });
    await page.goto(`${FRONTEND}${PAGE}${urlSuffix}`, { waitUntil: 'networkidle' });
    await page.screenshot({ path: `/tmp/walk-${PAGE.replaceAll('/','_')}-${flagState}-${label}.png`, fullPage: true });
    await ctx.close();
  }
}

await browser.close();
console.log(JSON.stringify({ errors }, null, 2));
```

Then for each page:

```bash
node /tmp/walk-<page>.mjs <route>
# Upload screenshots and collect Linear asset URLs
URLS=""
for img in /tmp/walk-<page>-*.png; do
  URL=$("${SYMPHONY_SCRIPTS}linear-upload-image.sh" "$img")
  URLS="$URLS\n![$(basename "$img" .png)]($URL)"
done
echo -e "$URLS"
```

If `npx playwright` fails to launch Chromium (first-run), do `npx --yes playwright install chromium` once and retry.

### Step 4: Walk every Contract row

For each row in the Contract:

1. Run the Playwright script for the route covering this row.
2. **Two-record rule.** Walk it on at least two representative records (empty + populated, two card variants, or one of each role-gated record). Add a second route invocation with a different record id.
3. **Click everything** the row covers — buttons, dropdowns, dialogs, drag targets, keyboard shortcuts. Extend the script with `page.click()` / `page.keyboard.press()` calls. The point is to surface event handlers that crash on second-render.
4. **Only when the work is a React-parity migration**: the script above already loads both URLs side-by-side. Diff the resulting screenshots character-by-character on copy, icon name, badge variant, dropdown option format. For work that isn't parity-bound, verify against the issue's own requirements instead — there is no React reference to diff against.
5. **Console must be clean.** The script's `errors` output is your evidence. New errors are blockers; pre-existing warnings are allowed only if listed in the Contract's "Known issues" section.
6. Mark the row in your scratchpad:
   - `✅ verified` — implemented and behaves like the spec
   - `⚠ partial` — implemented but with drift; describe the drift specifically
   - `❌ missing or broken` — not implemented, or implemented but crashes / misbehaves

### Step 5: Post the Tester Report

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

### Step 6: Stop

Do NOT modify code. Do NOT push. Do NOT open or close PRs. Your only output is the Tester Report comment.

End your turn cleanly after posting. The orchestrator reads the report and decides whether to dispatch the next phase or re-dispatch Implement.
