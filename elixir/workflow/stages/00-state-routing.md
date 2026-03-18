## Step 0: Setup and Route

SYMPHONY_PHASE: Investigate

Before doing anything:

1. `cd` to your working directory (from `.symphony_slot`)
2. Read the CLAUDE.md in the working directory for project conventions

### Claim the issue

Assign the issue to the current user and move it to "In Progress":

Using Linear MCP tools (preferred):
```
mcp__plugin_linear__save_issue with id="{{ issue.id }}", stateId=<In Progress state ID>, assigneeId=<your user ID>
```

Or fetch the state/user IDs first:
```
mcp__plugin_linear__list_issue_statuses for the team
mcp__plugin_linear__list_users to find the current user
```

Then update the issue with the correct state and assignee.

### Check current state

3. Check current git state — branch, uncommitted changes
4. Check for existing PRs: `gh pr list --head "$(git branch --show-current)" --json number,url,state`

Based on your findings:
- **No branch, no PR**: Start from Step 1 (Investigate)
- **Branch exists, no PR**: Resume from Step 2 (Implement)
- **PR exists, CI green, no review comments**: Go to Step 4 (Share Evidence) if not already done, then Step 6 (Done)
- **PR exists, CI failing or review comments**: Go to Step 2 (Implement) to fix
