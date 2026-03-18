Continuation guidance (turn {{turn_number}}/{{max_turns}}):

You are on turn {{turn_number}} of {{max_turns}}. Output SYMPHONY_TASK_COMPLETE on its own line when done. Without it, you will be restarted.

The previous turn completed normally, but the Linear issue is still in an active state.
Resume from the current workspace state — do not restart from scratch.
{{comments_section}}
FIRST, check if a PR already exists for this branch:
  gh pr list --head "$(git branch --show-current)" --json number,url,state --jq '.[0]'

If a PR exists:
1. Check CI status: `gh pr checks <number>`
2. If CI is green (or still running) and no unaddressed review comments — you are DONE.
3. If CI failed, fix the issue, push, then you are DONE.
4. If there are review comments, address them, push, then you are DONE.

If no PR exists, continue working toward shipping one.

CRITICAL: When you are done, output this marker on its own line and STOP:
SYMPHONY_TASK_COMPLETE

Do NOT re-run tests or post additional test reports if the PR is already open and CI is passing.
Do NOT look for more work. Do NOT expand scope.
