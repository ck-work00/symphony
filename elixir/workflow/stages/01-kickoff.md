## Step 1: Understand the Issue

Do NOT write any code. Do NOT search the codebase yet. Read first.

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

## Step 1b: Investigate the Codebase

Now search the codebase. Do NOT write code — only read.

1. Find the relevant files, modules, and functions for each requirement.
2. Trace the execution path. Understand how the current code works before deciding how to change it.
3. Identify patterns and conventions used in the area you'll be changing.
4. Check for existing tests that cover this code path.
5. Note anything surprising — code that doesn't work how you expected, missing abstractions, or tricky edge cases.

Use what you learn to **refine your understanding of the requirements**. Sometimes reading the code reveals that a requirement is more nuanced than the issue describes, or that it touches more files than expected.

## Step 1c: Post Your Implementation Plan to Linear

You MUST post a comment on the Linear issue before writing any code. This is how the team tracks your understanding and verifies your approach.

The comment must include:

1. **Requirements checklist** — every distinct requirement from the issue, as a markdown checkbox list:
   ```
   ## Requirements
   - [ ] Fix email sender attribution for forwarded messages
   - [ ] Update reply-to header to use original sender
   - [ ] Add test coverage for forwarding scenarios
   ```

2. **Implementation plan** — for each requirement, list:
   - Which files you will change
   - What you will add, modify, or remove
   - Your approach and why

3. **Risks or open questions** — anything unclear, risky, or that might need human input.

Post using the Linear MCP `save_comment` tool with the issue ID from the Issue Context above.

If MCP tools are not available, use curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "YOUR_COMMENT_HERE"}}'
```

**Do NOT proceed to Step 2 until this comment is posted.** The plan is your contract — you will implement exactly what you listed, nothing more and nothing less. If a requirement is unclear, say so in the plan rather than guessing.
