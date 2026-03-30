## Step 0: Setup and Route

Before doing anything:

1. `cd` to your working directory (from `.symphony_slot`)
2. Read the CLAUDE.md in the working directory for project conventions

### Check for existing work

3. Check for existing PRs for this issue — search by identifier, not current branch:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json number,url,state,headRefName --jq '.[]'
   ```
4. Check current git state — branch, uncommitted changes

**If an open PR exists for this issue:**
- Check out that PR's branch: `git checkout <branch-name>` (use the `headRefName` from the PR)
- Do NOT create a new branch or new PR
- Check CI status: `gh pr checks <number>`
- Check for review comments: `gh pr view <number> --json reviews,comments`
- Address any CI failures or review feedback, then push to the **same branch**
- Skip to the Implement phase

**If no PR exists:**
- Start from the Investigate phase
- When you create a branch, name it `{{ issue.identifier | downcase }}`
