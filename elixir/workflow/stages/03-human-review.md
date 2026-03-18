## Step 3: Human Review

Check CI status and review comments:

```bash
gh pr checks <number>
gh pr view <number> --json reviews,comments
```

- If CI is green and no unaddressed review comments — you are DONE.
- If CI failed — fix the issue, push, and check again.
- If there are review comments — address them and push.

SYMPHONY_TASK_COMPLETE
