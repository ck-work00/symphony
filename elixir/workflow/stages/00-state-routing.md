## Step 0: Setup and Route

Before doing anything:

1. `cd` to your working directory (from `.symphony_slot`)
2. Update and rebase with main:
   ```bash
   git fetch origin main
   git checkout main
   git pull --ff-only origin main
   ```
3. Read the CLAUDE.md in the working directory for project conventions

### Claim the issue

Assign the issue to Christian Koch and move it to "In Progress":

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"{{ issue.id }}\", input: { stateId: \"in_progress_state_id\", assigneeId: \"christian_koch_user_id\" }) { success } }"}'
```

To get the correct state and user IDs, first look them up:
```bash
# Find "In Progress" state ID
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "query { workflowStates(filter: { name: { eq: \"In Progress\" } }) { nodes { id name } } }"}' | python3 -c "import sys,json; [print(n['id'], n['name']) for n in json.load(sys.stdin)['data']['workflowStates']['nodes']]"

# Find Christian Koch's user ID
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "query { users(filter: { name: { contains: \"Christian\" } }) { nodes { id name } } }"}' | python3 -c "import sys,json; [print(n['id'], n['name']) for n in json.load(sys.stdin)['data']['users']['nodes']]"
```

Then update the issue with the correct IDs.

### Check for existing work

4. Check for existing PRs for this issue — search by identifier, not current branch:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json number,url,state,headRefName --jq '.[]'
   ```
5. Check current git state — branch, uncommitted changes

**If an open PR exists for this issue:**
- Check out that PR's branch: `git checkout <branch-name>` (use the `headRefName` from the PR)
- Rebase onto latest main: `git rebase origin/main`
- Do NOT create a new branch or new PR
- Skip to the Implement phase

**If no PR exists:**
- Create a branch from main: `git checkout -b {{ issue.identifier | downcase }}`
- Start from the Investigate phase
