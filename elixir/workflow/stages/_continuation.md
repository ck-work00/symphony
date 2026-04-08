Continuation guidance (turn {{turn_number}}/{{max_turns}}):

The previous turn completed normally, but the Linear issue is still in an active state.
Resume from the current workspace state — do not restart from scratch.
{{comments_section}}

## Check PR status

FIRST, check if a PR already exists for this branch:
```bash
gh pr list --head "$(git branch --show-current)" --json number,url,state --jq '.[0]'
```

### If a PR exists:

1. **Check @agent comments on Linear** — these are instructions from the team and take priority:
   ```bash
   curl -s -X POST https://api.linear.app/graphql \
     -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
     -H "Content-Type: application/json" \
     -d '{"query": "query { issue(id: \"{{issue_id}}\") { comments { nodes { body createdAt user { name } } } } }"}' \
     | python3 -c "import sys,json; [print(f'{c[\"user\"][\"name\"]}: {c[\"body\"]}') for c in json.load(sys.stdin)['data']['issue']['comments']['nodes'] if '@agent' in c['body'].lower()]"
   ```
   If there are @agent comments, follow their instructions FIRST.
2. **Check CI status**: `gh pr checks <number>`
3. **Fetch review comments** (CodeRabbit and human reviewers):
   ```bash
   gh pr view <number> --json reviews,comments --jq '.reviews[] | "\(.author.login): \(.state) - \(.body)"'
   gh api repos/{owner}/{repo}/pulls/<number>/comments --jq '.[] | "\(.user.login) on \(.path):\(.line): \(.body)"'
   ```
4. **If CI failed**: Fix the failing tests/checks, push, then check again.
5. **If there are unaddressed review comments**: Read each comment, make the requested changes, push, and re-run tests.
6. **If CI is green and all review comments are addressed**: You are done.

**ALWAYS fetch and rebase before pushing:**
```bash
git fetch origin main && git rebase origin/main
```
If there are conflicts, resolve them. Then `git push --force-with-lease`.

### If no PR exists:
Continue working toward shipping one.

Do NOT re-run tests or post additional test reports if the PR is already open and CI is passing.
Do NOT look for more work. Do NOT expand scope.
