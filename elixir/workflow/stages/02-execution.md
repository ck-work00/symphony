## Step 2: Implement

SYMPHONY_PHASE: Implement

The branch `{{ issue.identifier | downcase }}` is already checked out in your working directory.

1. Make the changes following the repository conventions (see CLAUDE.md).
2. Keep changes focused — solve the issue, nothing more.
3. Format code: `direnv exec . mix format` (Elixir) and/or `cd frontend && npm run format` (frontend).

## Step 3: Test

SYMPHONY_PHASE: Test

### Unit tests (required)

1. Write unit tests for every significant code path you changed or added.
2. Cover the happy path, edge cases, and error conditions.
3. Run static analysis: `direnv exec . mix check`
4. Run the full test suite: `direnv exec . mix test`
5. All new and existing tests must pass. Fix failures before proceeding.

### Browser testing (MANDATORY — do NOT skip)

You MUST open a browser and verify your changes visually. You have Playwright MCP tools available — use them.

Source the port numbers first:
```bash
cat .symphony_slot  # or source it
```

Then follow these exact steps:

1. **Navigate** to the relevant page in the frontend (use the FRONTEND_PORT from .symphony_slot):
   - Use the `browser_navigate` Playwright tool with URL `http://localhost:<FRONTEND_PORT>/...`
   - Log in if needed using test credentials from the CLAUDE.md

2. **Interact** with the UI to exercise the flow described in the issue:
   - Click buttons, fill forms, navigate between pages
   - Use `browser_click`, `browser_fill_form`, `browser_snapshot` tools

3. **Verify** the fix works — check that the expected behavior matches what you see

4. **Take screenshots** at key moments (before/after the fix, the final state):
   - Use the `browser_take_screenshot` Playwright tool
   - Save each screenshot with a descriptive filename

You will upload these screenshots to the Linear issue in the next step.

**If you skip browser testing, the work is not complete. Do NOT move to Step 4 without screenshots.**
