## Step 0: Determine State and Route

SYMPHONY_PHASE: Investigate

Before doing anything, determine your current state:

1. Check if a branch already exists for this issue
2. Check if a PR already exists
3. Check if there are uncommitted changes in the workspace

Based on your findings:
- **No branch, no PR**: Start from Step 1 (Kickoff)
- **Branch exists, no PR**: Resume from Step 2 (Execution)
- **PR exists**: Go to Step 3 (Human Review)
- **PR with review comments**: Go to Step 4 (Rework)
