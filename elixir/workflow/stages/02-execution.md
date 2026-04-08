## Implement

### Get your plan

Read the implementation plan from the Linear issue comments. Your plan was posted in a previous phase — fetch the comments on issue `{{ issue.id }}` and find the one with "## Requirements".

That checklist is your contract. Implement exactly what it says.

### Write tests FIRST (backend changes)

For each backend (Elixir) requirement in the plan:

1. **Write a failing test** that covers the requirement. Place tests in the corresponding `test/` directory following existing conventions.
2. **Run the test** to confirm it fails: `direnv exec . mix test <test_file>`
3. Only then move to the implementation step below.

Focus on testing core business logic and behavior changes. You don't need 100% coverage of every file, but new features and bug fixes must have tests that verify the expected behavior. Frontend (TypeScript) changes do not require unit tests unless the change is to shared logic or utilities.

### Implement to make tests pass

Work through the requirements checklist one item at a time:

1. Write the implementation code to make your failing tests pass.
2. Run `direnv exec . mix test` after each requirement to verify nothing broke.
3. Follow existing patterns in the files you're editing.
4. Keep changes focused — implement what you planned, nothing more.

After all requirements are implemented:
- Run the full test suite: `direnv exec . mix test`
- Run static analysis: `direnv exec . mix check`
- Format code: `direnv exec . mix format`

All tests must pass before proceeding.

### Verify test coverage

Before committing, check that your backend changes have tests:

```bash
# Elixir source files you changed
git diff origin/main --name-only -- lib/

# Test files you changed
git diff origin/main --name-only -- test/
```

If you added or changed backend business logic without a corresponding test, add one. Frontend-only changes (components, styles) don't need unit tests.

### Check Linear issue for @agent feedback

Before committing, check the Linear issue for any `@agent` comments with instructions from the team:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "query { issue(id: \"{{ issue.id }}\") { comments { nodes { body createdAt user { name } } } } }"}' \
  | python3 -c "import sys,json; [print(f'{c[\"user\"][\"name\"]}: {c[\"body\"]}') for c in json.load(sys.stdin)['data']['issue']['comments']['nodes'] if '@agent' in c['body'].lower()]"
```

If there are `@agent` comments with instructions, follow them before proceeding.

### Commit and create PR

1. Commit with a clear message: `{{ issue.identifier }}: <summary>`
2. Fetch and rebase before pushing — ALWAYS:
   ```bash
   git fetch origin main
   git rebase origin/main
   ```
   If there are conflicts, resolve them before continuing.
3. Push and create PR:
   ```bash
   git push -u origin {{ issue.branch_name }}
   gh pr create --title "{{ issue.identifier }}: <title>" --body "<description>\n\nLinear: {{ issue.identifier }}"
   ```
4. Post the PR link as a comment on the Linear issue.

### Done

You have completed the Implement phase. Stop here.
Your deliverables: tests written for every changed source file, code implemented, PR created with CI running.
