## Simplify

Review the PR changes for clarity, consistency, and unnecessary complexity.

### Review the diff

```bash
git diff origin/main --stat
git diff origin/main
```

Look for:
- Duplicated logic that could be extracted
- Overly complex conditionals that can be simplified
- Inconsistent naming or patterns relative to the surrounding code
- Dead code or unnecessary changes
- Missing or misleading comments
- Opportunities to reuse existing utilities or patterns in the codebase

### Simplify

Make targeted improvements. Rules:
- Only touch files in the PR diff — do not refactor unrelated code
- Do not add features or change behavior
- Do not add unnecessary abstractions for one-time operations
- Prefer clarity over cleverness

### Run tests

After any changes: `direnv exec . mix test && direnv exec . mix check`

### Commit and push

If you made changes:
```bash
git add -A && git commit -m "{{ issue.identifier }}: simplify" && git push
```

If no changes were needed, post a comment on the Linear issue: "Reviewed for simplification — no changes needed."

### Done

You have completed the Simplify phase. Stop here.
