## Step 4: Share Evidence on Linear (MANDATORY — do NOT skip)

You MUST post test results to the **Linear issue** — NOT to the GitHub PR. The team reviews evidence on Linear.

### What to post

Post a single comment on the Linear issue that includes:
- What you tested and how
- Test results (unit tests passing, browser verification)
- Screenshots embedded as images

### How to post

Use the Linear MCP `save_comment` tool with the issue ID from the Issue Context section of your prompt (`{{ issue.id }}`).

If MCP tools are not available, use curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n**Unit tests**: All passing\n**Browser verification**: Confirmed fix works"}}'
```

### Important

- Post to **Linear**, not GitHub. GitHub comments are not monitored for evidence.
- Do NOT proceed to Step 5 (Ship) without posting evidence to the Linear issue.
