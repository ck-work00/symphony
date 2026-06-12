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

#### Login

1. Navigate to `http://localhost:$FRONTEND_PORT`
2. Log in with the dispatcher test account:
   - Email: `$(whoami)+dispatcher@gearflow.com`
   - Password: `Test1234!`
3. Wait for the dashboard to load

#### Smoke test — navigate core pages

After login, navigate to each of these index pages and confirm they load without errors:
- `/tickets` (Tickets)
- `/equipment` (Equipment)
- `/mobilizations` (Mobilizations)
- `/maintenance` (Maintenance)

Take a screenshot of at least the Equipment page as baseline evidence.

#### Issue-specific testing

Read the issue description to understand what changed. If the change is user-facing:
- Navigate to the affected page(s)
- Exercise the specific flow described in the issue
- Take screenshots at each key step showing the change works
- If the issue involves role restrictions, test with the appropriate role accounts:
  - Dispatcher: `$(whoami)+dispatcher@gearflow.com`
  - Requester: `$(whoami)+requester@gearflow.com`
  - Manager: `$(whoami)+manager@gearflow.com`

If the change is backend-only (no UI impact), the smoke test screenshots are sufficient.

### Step 3: Upload screenshots and post to Linear

Upload the screenshots you captured and collect ready-to-paste markdown. Pass
the ACTUAL files you saved (any names). The helper uploads each to Linear,
prints one `![name](assetUrl)` line per file, and NEVER prints an empty `![]()`:

```bash
URLS=$("${SYMPHONY_SCRIPTS}linear-embed-images.sh" /tmp/evidence-*.png)   # <- use YOUR real screenshot paths
```

If `$URLS` is empty the upload failed — do NOT post empty `![]()`; fix the paths
and re-run. Then post a comment with the embedded screenshots:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Browser Test Results\n\nLogged in and verified core pages load. Screenshots below.\n\n'"$URLS"'"}}'
```

### Done

Stop here. Do not read source code. Do not investigate. Do not fix anything.
