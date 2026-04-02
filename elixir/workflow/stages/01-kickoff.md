## Investigate

Do NOT write any code. This phase is research and planning only.

### Read the issue

1. Read the **full issue description** — every word, not just the title.
2. Read **every comment** on the issue, oldest to newest. Comments often contain clarifications, updated requirements, or decisions that override the original description.
3. Open and read **every linked issue** referenced in the description. These provide context the main issue assumes you already know.
4. Look at any **attachments, screenshots, or videos**. If the issue describes a UI problem, understand exactly what the user sees.
5. **Extract every requirement.** List each distinct thing the issue asks for. Issues often contain multiple items — a bug fix AND a UI change, or three separate behaviors to implement. Miss nothing.

After reading, you should be able to answer:
- What is the problem or desired outcome?
- Who is affected and how?
- What are ALL the acceptance criteria?
- Are there open questions or ambiguities?

### Search the codebase

Now search the codebase. Do NOT write code — only read.

Use the **Agent tool with `subagent_type: "Explore"`** for broad searches — this runs in a separate context so your main context stays clean. Use Grep/Glob for targeted lookups.

1. Find the relevant files, modules, and functions for each requirement.
2. Trace the execution path. Understand how the current code works before deciding how to change it.
3. Identify patterns and conventions used in the area you'll be changing.
4. Check for existing tests that cover this code path.
5. Note anything surprising — code that doesn't work how you expected, missing abstractions, or tricky edge cases.

Use what you learn to **refine your understanding of the requirements**. Sometimes reading the code reveals that a requirement is more nuanced than the issue describes, or that it touches more files than expected.

### Post your implementation plan to Linear

First, check if a plan has already been posted by fetching the issue comments and looking for "## Requirements". If a plan already exists, skip this step — do NOT post a duplicate.

If no plan exists, post a comment on the Linear issue using curl:

The comment must include:

1. **Requirements checklist** — every distinct requirement as a markdown checkbox list:
   ```
   ## Requirements
   - [ ] Fix email sender attribution for forwarded messages
   - [ ] Update reply-to header to use original sender
   - [ ] Add test coverage for forwarding scenarios
   ```

2. **Implementation plan** — for each requirement:
   - Which files you will change
   - What you will add, modify, or remove
   - Your approach and why

3. **Risks or open questions** — anything unclear, risky, or that might need human input.

If MCP tools are not available, use curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "YOUR_COMMENT_HERE"}}'
```

### Done

You have completed the Investigate phase. Stop here. Do not write any code.
Your deliverable is the Linear comment with the requirements checklist and implementation plan.
