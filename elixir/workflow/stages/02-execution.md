## Step 2: Implement

SYMPHONY_PHASE: Implement

The branch `{{ issue.identifier | downcase }}` is already checked out in your working directory.

1. Make the changes following the repository conventions (see CLAUDE.md).
2. Keep changes focused — solve the issue, nothing more.
3. Format code: `direnv exec . mix format` (Elixir) and/or `cd frontend && npm run format` (frontend).

## Step 3: Test

SYMPHONY_PHASE: Test

**Writing tests is a critical requirement.** All core functionality you add or change MUST have test coverage.

### Unit tests

1. Write unit tests for every significant code path you changed or added.
2. Cover the happy path, edge cases, and error conditions.
3. Run static analysis: `direnv exec . mix check`
4. Run the full test suite: `direnv exec . mix test`
5. All new and existing tests must pass. Fix failures before proceeding.

### Browser testing (required)

Use Playwright MCP tools to verify the fix works in a real browser. Backend and frontend are already running on the ports from `.symphony_slot`.

1. Navigate to the relevant page using `mcp__plugin_playwright__browser_navigate`
2. Exercise the flow that the issue describes
3. Verify the expected behavior
4. Take screenshots at key steps using `mcp__plugin_playwright__browser_take_screenshot`
5. Save each screenshot — you will upload these in the next step

If the issue involves UI changes, browser testing is mandatory. If it's a pure backend change, at minimum verify the API response is correct.
