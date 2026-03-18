Continuation guidance (turn {{turn_number}}/{{max_turns}}):

You are on turn {{turn_number}} of {{max_turns}}. Output SYMPHONY_TASK_COMPLETE on its own line when done. Without it, you will be restarted.

The previous turn completed normally, but the Linear issue is still in an active state.
Resume from the current workspace state — do not restart from scratch.
{{comments_section}}

## Check PR status

FIRST, check if a PR already exists for this branch:
```bash
gh pr list --head "$(git branch --show-current)" --json number,url,state --jq '.[0]'
```

### If a PR exists:

1. **Check CI status**: `gh pr checks <number>`
2. **Fetch review comments** (CodeRabbit and human reviewers):
   ```bash
   gh pr view <number> --json reviews,comments --jq '.reviews[] | "\(.author.login): \(.state) - \(.body)"'
   gh api repos/{owner}/{repo}/pulls/<number>/comments --jq '.[] | "\(.user.login) on \(.path):\(.line): \(.body)"'
   ```
3. **If CI failed**: Fix the failing tests/checks, push, then check again.
4. **If there are unaddressed review comments**: Read each comment, make the requested changes, push, and re-run tests.
5. **If CI is green and all review comments are addressed**: You are DONE.

### If no PR exists:
Continue working toward shipping one.

## When done

Output this marker on its own line and STOP:
SYMPHONY_TASK_COMPLETE

Do NOT re-run tests or post additional test reports if the PR is already open and CI is passing.
Do NOT look for more work. Do NOT expand scope.
