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

### If the browser or dev server is broken

Do NOT skip browser testing and write an excuse. Fix it or escalate:

1. **Restart the dev server**: `~/.claude/scripts/devenv-start.sh`
2. **Clear caches**: `rm -rf node_modules/.vite && cd frontend && rm -rf node_modules/.vite`
3. **Restart and retry**: After clearing caches, restart the dev server and try again.
4. **If still broken**: Use `SYMPHONY_NEEDS_HELP: Browser testing blocked — <describe the error>` and STOP. Do not proceed without browser verification. Do not ship evidence that says "could not complete browser testing."

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
