## Implement

### Get your plan

Read the implementation plan from the Linear issue comments. Your plan was posted in a previous phase — fetch the comments on issue `{{ issue.id }}` and find the one with "## Requirements".

That checklist is your contract. Implement exactly what it says.

### Write tests FIRST

For each requirement in the plan:

1. **Write a failing test** that covers the requirement. Place tests in the corresponding `test/` directory following existing conventions.
2. **Run the test** to confirm it fails: `direnv exec . mix test <test_file>`
3. Only then move to the implementation step below.

Cover the happy path, edge cases, and error conditions for each requirement. Do not skip test writing — it is not optional.

### Implement to make tests pass

Work through the requirements checklist one item at a time:

1. Write the implementation code to make your failing tests pass.
2. Run `direnv exec . mix test` after each requirement to verify nothing broke.
3. Follow repository conventions (see CLAUDE.md).
4. Keep changes focused — implement what you planned, nothing more.

After all requirements are implemented:
- Run the full test suite: `direnv exec . mix test`
- Run static analysis: `direnv exec . mix check`
- Format code: `direnv exec . mix format`

All tests must pass before proceeding.

### Test coverage rule

**Every source file you changed or created MUST have corresponding test coverage.** This is not optional. Before committing, verify:

```bash
# List source files you changed
git diff origin/main --name-only | grep -v _test

# List test files you changed
git diff origin/main --name-only | grep _test
```

If a source file has no corresponding test file in the diff, write tests for it before proceeding. This applies to bug fixes, nil guards, helper extractions — every change, no matter how small.

### Commit and create PR

1. Commit with a clear message: `{{ issue.identifier }}: <summary>`
2. Push and create PR:
   ```bash
   git push -u origin {{ issue.identifier | downcase }}
   gh pr create --title "{{ issue.identifier }}: <title>" --body "<description>"
   ```
3. Post the PR link as a comment on the Linear issue.

### Wait for CI and fix failures

After creating the PR, wait for CI to run and check the result:

```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')
# Wait up to 5 minutes for CI to start
sleep 60
gh pr checks $PR_NUM
```

If any checks fail:
1. Read the failure output: `gh pr checks $PR_NUM --json name,state,output --jq '.[] | select(.state != "SUCCESS")'`
2. Fix the issue locally
3. Run `direnv exec . mix check` to verify it passes
4. Commit and push the fix

Do not leave the Implement phase with failing CI.

### Done

You have completed the Implement phase. Stop here.
Your deliverables: tests written for every changed source file, code implemented, PR created, CI passing.
