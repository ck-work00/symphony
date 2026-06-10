## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

Your job: log in to the app, verify it works in a real browser, take screenshots, and post them to Linear. Do NOT read source code, do NOT investigate the codebase, do NOT fix anything.

### Step 1: Get your workspace info

```bash
source .symphony_slot
cd $DIRECTORY
```

### Step 2: Browser testing

Test the app in a real browser.

#### Browser tooling

Playwright with Chromium is installed globally — drive it from a small node script, NOT via a Playwright MCP server (MCP burns enormous context). Write the script to `/tmp/evidence.js` and run with `NODE_PATH=$(npm root -g) node /tmp/evidence.js`:

```js
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(`http://localhost:${process.env.FRONTEND_PORT}`);
  // ... log in, navigate, then:
  await page.screenshot({ path: '/tmp/evidence-page.png', fullPage: true });
  await browser.close();
})();
```

#### Login

1. Navigate to `http://localhost:$FRONTEND_PORT`
2. Log in with the dispatcher test account:
   - Email: `${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com`
   - Password: `Test1234!`
3. Wait for the dashboard to load

#### Smoke test — navigate core pages

After login, navigate to each of these index pages and confirm they load without errors:
- `/issues` (Issues)
- `/requisitions` (Requisitions)
- `/mobilizations` (Mobilizations)
- `/maintenance` (Maintenance)

Take a screenshot of at least the Requisitions page as baseline evidence.

#### Issue-specific testing

Read the issue description to understand what changed. If the change is user-facing:
- Navigate to the affected page(s)
- Exercise the specific flow described in the issue
- Take screenshots at each key step showing the change works
- If the issue involves role restrictions, test with the appropriate role accounts:
  - Dispatcher: `${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com`
  - Requester: `${GF_EMAIL_HANDLE:-$(whoami)}+requester@gearflow.com`
  - Manager: `${GF_EMAIL_HANDLE:-$(whoami)}+manager@gearflow.com`

If the change is backend-only (no UI impact), the smoke test screenshots are sufficient.

### Step 3: Upload screenshots and post to Linear

Upload each screenshot and collect the asset URLs:

```bash
URLS=""
for img in /tmp/evidence-*.png; do
  URL=$("${SYMPHONY_SCRIPTS}linear-upload-image.sh" "$img")
  URLS="$URLS\n![$(basename "$img" .png)]($URL)"
done
```

Post a comment with all screenshots:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Browser Test Results\n\nLogged in and verified core pages load. Screenshots below.\n\n'"$(echo -e "$URLS")"'"}}'
```

### Done

Stop here. Do not read source code. Do not investigate. Do not fix anything.
