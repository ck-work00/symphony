## Step 2: Execution

SYMPHONY_PHASE: Implement

1. Implement the changes according to your plan
2. Write tests for new functionality
3. Run the test suite to verify

SYMPHONY_PHASE: Test

4. Fix any failing tests
5. Run the full test suite one final time

SYMPHONY_PHASE: Ship

6. Commit your changes with a clear message
7. Push the branch and create a PR:
   ```bash
   git push -u origin HEAD
   gh pr create --title "<issue-identifier>: <brief summary>" --body "<description>"
   ```
