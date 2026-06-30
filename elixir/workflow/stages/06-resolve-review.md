## Resolve Review

The plan is code-complete and tester-approved, but a reviewer (CodeRabbit and/or
a human) **requested changes**, so the PR is blocked. Your only job this phase is
to drive the review to approved. Do not add features or refactor unrelated code.

CodeRabbit runs in **request-changes mode** (org-wide): its review submits as
`CHANGES_REQUESTED` and **blocks merge even when CI is green**. A green
"CodeRabbit" status check only means it *ran*, not that its comments are
resolved. You are not done until **every** thread is resolved and the review has
flipped to APPROVED on the current HEAD.

### Step 1: Re-orient

```bash
cd "$(grep -oE 'DIRECTORY=[^ ]+' .symphony_slot | cut -d= -f2)"
source .symphony_slot
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')
HEAD=$(gh pr view $PR_NUM --json headRefOid --jq .headRefOid)
```

### Step 2: List EVERY open review thread

Resolve them all — do not cherry-pick. Get the unresolved threads with their
comment bodies (some bodies are collapsed under `<details>` — read them in full):

```bash
gh api graphql -f query='
{ repository(owner:"{owner}",name:"{repo}"){ pullRequest(number:'"$PR_NUM"'){
  reviewThreads(first:100){ nodes { id isResolved
    comments(first:5){ nodes { author{login} path line body } } } } } } }'
```

Also confirm CodeRabbit reviewed your latest push (its newest review's `commit_id`
must equal `$HEAD`; if not, it hasn't seen your changes yet — wait for re-review
before assuming a thread is stale):

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUM/reviews \
  --jq '[.[] | select(.user.login | startswith("coderabbit"))] | last | {state, commit_id}'
```

### Step 3: For EVERY thread, fix it or reply to it — no silent ignores

- **Valid finding** → make the change (with a test if code changed), commit, push.
- **Not applicable / out of scope / wrong** → reply on the thread explaining why.

Every thread must end with either a pushed fix or a reply. Don't leave any
untouched. Run `direnv exec . mix check` and `direnv exec . mix test` after code
changes.

### Step 4: Resolve and exit the gate

Once every thread is fixed-or-replied and CI is green, post:

```bash
gh pr comment $PR_NUM --body "@coderabbitai resolve"
```

CodeRabbit resolves its threads and auto-flips its review `CHANGES_REQUESTED →
APPROVED` within a minute or two (CI must be green). For human review threads,
resolve them via the GraphQL `resolveReviewThread` mutation after replying.

### Step 5: Never bypass it

Do **NOT** dismiss the review and do **NOT** `--admin` merge — the harness denies
both, and the orchestrator will keep reopening this issue while the review is
`CHANGES_REQUESTED`. If CodeRabbit hasn't approved a few minutes after every
thread is resolved and CI is green, emit `SYMPHONY_NEEDS_HELP: CodeRabbit stuck
at CHANGES_REQUESTED despite resolved threads + green CI` and stop — a human
dismissal is the only fallback.

### Step 6: Stop

End your turn after pushing and posting `@coderabbitai resolve`. The orchestrator
re-checks the review gate: approved → the issue ships; still requesting changes →
it dispatches Resolve Review again with what remains. Do not poll the review
yourself and do not move the issue's status.
