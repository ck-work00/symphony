---
tracker:
  kind: linear
  filter:
    labels:
      include:
        - symphony-agent
  active_states:
    - Shaped
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    # Route to a pool slot based on issue labels
    REPO="${SYMPHONY_REPO:-platform}"
    if [ -z "$REPO" ]; then
      REPO="platform"
    fi
    BRANCH="${SYMPHONY_ISSUE_IDENTIFIER:-main}"
    WORKSPACE="$(pwd)"
    ~/.claude/scripts/symphony-slot-claim.sh "$REPO" "$BRANCH" "$WORKSPACE"
  before_remove: |
    WORKSPACE="$(pwd)"
    ~/.claude/scripts/symphony-slot-release.sh "$WORKSPACE"
agent:
  backend: claude
  max_concurrent_agents: 1
  max_turns: 20
claude:
  command: claude
  dangerously_skip_permissions: true
  max_turns: 25
  stall_timeout_ms: 600000
  turn_timeout_ms: 3600000
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
escalation:
  eval_score_threshold: 60
server:
  port: 4000
---
