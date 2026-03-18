## Step 5: Ship

SYMPHONY_PHASE: Ship

1. Commit all changes with a clear message: `{{ issue.identifier }}: <summary>`
2. Push the branch and create a PR:
   ```bash
   git push -u origin {{ issue.identifier | downcase }}
   gh pr create --title "{{ issue.identifier }}: <title>" --body "<description>"
   ```
3. Post the PR link as a comment on the Linear issue.

## Step 6: Done

After shipping the PR, output exactly this marker on its own line:

```
SYMPHONY_TASK_COMPLETE
```

Then STOP. Do not continue working. Do not look for more work.
Issue status transitions happen automatically via PR merge and deploy automations. Never move an issue's status yourself.
