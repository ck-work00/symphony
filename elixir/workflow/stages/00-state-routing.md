## Step 0: Determine State and Route

SYMPHONY_PHASE: Investigate

Before doing anything:

1. `cd` to your working directory (from `.symphony_slot`)
2. Read the CLAUDE.md in the working directory for project conventions
3. Check current git state — branch, uncommitted changes, existing PRs

Based on your findings:
- **No branch, no PR**: Start from Step 1 (Investigate)
- **Branch exists, no PR**: Resume from Step 2 (Implement)
- **PR exists, CI green**: Go to Step 4 (Share Evidence) if not already done, then Step 5 (Done)
- **PR exists, CI failing or review comments**: Go to Step 2 (Implement) to fix
