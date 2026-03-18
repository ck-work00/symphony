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

### Browser testing (required — do NOT skip this)

You MUST verify your changes in a real browser using Playwright MCP tools. The backend and frontend are already running on the ports from `.symphony_slot`.

1. Source the slot info: `source .symphony_slot` (or read PHOENIX_PORT/FRONTEND_PORT from it)
2. Navigate to the relevant page: `mcp__plugin_playwright__browser_navigate` to `http://localhost:$FRONTEND_PORT/...`
3. Exercise the flow that the issue describes — interact with the UI as a user would
4. Verify the expected behavior works correctly
5. Take screenshots at each key step: `mcp__plugin_playwright__browser_take_screenshot`
6. Save screenshots — you MUST upload them to the Linear issue in the next step

If the issue involves UI changes, you must visually confirm the fix. If it's a pure backend/API change, at minimum verify the API endpoint works via browser or curl.

**Do NOT proceed to Step 4 (Share Evidence) without browser screenshots.**
