## Simplify

### Address PR review feedback

First, check for review comments on the PR:

```bash
gh pr view $(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number') --json reviews,comments --jq '.reviews[] | "\(.author.login): \(.state) - \(.body)"'
gh api repos/{owner}/{repo}/pulls/$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')/comments --jq '.[] | "\(.user.login) on \(.path):\(.line): \(.body)"'
```

If there are actionable review comments (from CodeRabbit or human reviewers):
1. Read each comment carefully
2. Make the requested changes
3. Write tests for any changes you make
4. Push the fixes

### Review the diff for simplification

```bash
git diff origin/main --stat
git diff origin/main
```

Look for:
- Duplicated logic that could be extracted
- Overly complex conditionals that can be simplified
- Inconsistent naming or patterns relative to the surrounding code
- Dead code or unnecessary changes
- Opportunities to reuse existing utilities or patterns in the codebase

### Check test coverage

Verify every changed source file has test coverage:

```bash
git diff origin/main --name-only | grep -v _test
```

If any source file lacks tests, write them. This takes priority over simplification.

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

If no changes were needed, post a comment on the Linear issue: "Reviewed for simplification — no changes needed."

### Done

You have completed the Simplify phase. Stop here.
