## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

### Run browser tests

Browser testing is mandatory. You have Playwright MCP tools available. Source the port numbers first:
```bash
cat .symphony_slot
```

1. **Navigate** to the relevant page using the FRONTEND_PORT from `.symphony_slot`.
2. **Exercise the flow** described in the issue — click buttons, fill forms, verify behavior.
3. **Take screenshots** at key moments (before/after, final state) using the `browser_take_screenshot` tool.

### Before opening the browser

The Vite dev server accumulates stale HMR state from code changes. Clear it before testing:

```bash
source .symphony_slot
cd $DIRECTORY/frontend && rm -rf node_modules/.vite
# Kill the existing Vite process and restart
pkill -f "vite.*$FRONTEND_PORT" 2>/dev/null
cd $DIRECTORY && ~/.claude/scripts/devenv-start.sh
```

Wait for the frontend to come back up before navigating.

### If the browser or dev server is broken

Do NOT skip browser testing and write an excuse. Fix it or escalate:

1. **Clear Vite cache and restart** (see above)
2. **If the app loads but has JS errors**: Check the browser console. If the error is in your code, fix it. If it's pre-existing on main, note it but still test what you can.
3. **If still broken after restart**: Use `SYMPHONY_NEEDS_HELP: Browser testing blocked — <describe the error>` and STOP. Do not proceed without browser verification. Do not ship evidence that says "could not complete browser testing."

A test report without browser screenshots is incomplete. Do not post it.

### Post evidence to Linear

Post a single comment on the Linear issue that includes:
- What you tested and how
- Test results (unit tests passing, browser verification)
- Screenshots embedded as images

Use the Linear MCP `save_comment` tool with issue ID `{{ issue.id }}`.

If MCP tools are not available, use curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n**Unit tests**: All passing\n**Browser verification**: Confirmed fix works"}}'
```

Post to **Linear**, not GitHub. GitHub comments are not monitored for evidence.

### Done

You have completed the Share Evidence phase. Stop here.
Your deliverable is the Linear comment with test results AND browser screenshots.
