## Simplify

### Check CI status

First, check if CI passed on the PR:

```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')
gh pr checks $PR_NUM
```

If any checks failed:
1. Read the failure details: `gh pr checks $PR_NUM --json name,state --jq '.[] | select(.state != "SUCCESS")'`
2. Fix the issue locally
3. Run `direnv exec . mix check` to verify
4. Commit and push the fix

Do not proceed with simplification until CI is green.

### Address PR review feedback

Check for review comments on the PR:

```bash
gh pr view $PR_NUM --json reviews,comments --jq '.reviews[] | "\(.author.login): \(.state) - \(.body)"'
gh pr view $PR_NUM --json comments --jq '.comments[] | "\(.author.login): \(.body)"'
```

If there are actionable review comments (from CodeRabbit or human reviewers):
1. Read each comment carefully
2. Make the requested changes
3. Write tests for any changes you make
4. Push the fixes

### Check test coverage

Verify every changed source file has test coverage:

```bash
git diff origin/main --name-only | grep -v _test
```

If any source file lacks tests, write them. This takes priority over simplification.

### Review the diff for simplification

```bash
git diff origin/main --stat
```

Then read specific files that look like they need simplification — do NOT dump the entire diff.

Look for:
- Duplicated logic that could be extracted
- Overly complex conditionals that can be simplified
- Inconsistent naming or patterns relative to the surrounding code
- Dead code or unnecessary changes
- Opportunities to reuse existing utilities or patterns in the codebase

### Simplify

Make targeted improvements. Rules:
- Only touch files in the PR diff — do not refactor unrelated code
- Do not add features or change behavior
- Do not add unnecessary abstractions for one-time operations
- Prefer clarity over cleverness
- Any new code you write also needs test coverage

### Run tests

After any changes: `direnv exec . mix test && direnv exec . mix check`

### Commit and push

If you made changes:
```bash
git add -A && git commit -m "{{ issue.identifier }}: simplify and address review feedback" && git push
```

If no changes were needed, post a comment on the **Linear issue** (NOT GitHub):
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "Reviewed for simplification — no changes needed."}}'
```

### Done

You have completed the Simplify phase. Stop here.
