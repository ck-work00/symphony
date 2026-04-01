## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

### Prepare the browser environment

1. Source the slot info and read the project's CLAUDE.md for test credentials and browser testing instructions:
   ```bash
   source .symphony_slot
   cat $DIRECTORY/CLAUDE.md | head -100
   ```

2. Clear stale Vite state and restart the frontend:
   ```bash
   cd $DIRECTORY/frontend && rm -rf node_modules/.vite
   pkill -f "vite.*$FRONTEND_PORT" 2>/dev/null
   cd $DIRECTORY && ~/.claude/scripts/devenv-start.sh
   ```

3. Wait for the frontend to come back up, then verify it loads:
   ```
   browser_navigate to http://localhost:$FRONTEND_PORT
   browser_snapshot to check the page rendered
   ```

### Run browser tests

Use the Playwright MCP tools. The workflow is: **Navigate → Snapshot → Interact → Screenshot**.

1. **Log in** using test credentials from CLAUDE.md (password is typically `gearflow2025`).
2. **Navigate** to the page affected by your changes.
3. **Exercise the flow** described in the issue — click buttons, fill forms, verify the behavior matches what was implemented.
4. **Take screenshots** at key moments using `browser_take_screenshot`. Save them with descriptive filenames.

You must verify that your changes work AND that nothing is visibly broken.

### If the browser or dev server is broken

Do NOT skip browser testing and write an excuse. Fix it or escalate:

1. **Clear Vite cache and restart** (see above).
2. **If the app loads but has JS errors**: Check the browser console with `browser_console_messages`. If the error is in your code, fix it. If pre-existing on main, note it but still test what you can.
3. **If still broken after restart**: Use `SYMPHONY_NEEDS_HELP: Browser testing blocked — <describe the error>` and STOP. Do not proceed. Do not post evidence without screenshots.

### Post evidence to Linear

Post a single comment on the Linear issue that includes:
- What you tested and how (specific pages, flows exercised)
- Test results (unit tests passing, browser verification)
- Screenshots embedded as images (upload via Linear file upload API or reference URLs)

Use the Linear MCP `save_comment` tool with issue ID `{{ issue.id }}`.

If MCP tools are not available, use curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n**Unit tests**: All passing\n**Browser verification**: Confirmed fix works\n\n![screenshot](URL)"}}'
```

Post to **Linear**, not GitHub.

### Done

You have completed the Share Evidence phase. Stop here.
Your deliverable is the Linear comment with test results AND browser screenshots.
