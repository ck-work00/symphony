# Seeds historical run data for development.
#
# Usage: mix run priv/repo/seeds.exs

alias SymphonyElixir.History

now = DateTime.utc_now()

# Helper to generate a time N hours ago
hours_ago = fn h -> DateTime.add(now, -h * 3600, :second) end

runs = [
  # --- Completed successes ---
  %{
    issue_id: "id-001", issue_identifier: "SYM-101", issue_title: "Fix pagination off-by-one in search results",
    issue_priority: 2, issue_labels: ["symphony-agent", "bug"],
    started_at: hours_ago.(48), finished_at: hours_ago.(47),
    outcome: "completed", agent_backend: "codex", turns_used: 8, total_tokens: 42_300,
    input_tokens: 31_200, output_tokens: 11_100, wall_clock_ms: 3_420_000,
    final_phase: "Ship",
    eval_score: 90, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/101",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 4, eval_lines_changed: 62
  },
  %{
    issue_id: "id-002", issue_identifier: "SYM-102", issue_title: "Add retry logic for webhook delivery",
    issue_priority: 1, issue_labels: ["symphony-agent", "enhancement"],
    started_at: hours_ago.(44), finished_at: hours_ago.(43),
    outcome: "completed", agent_backend: "codex", turns_used: 12, total_tokens: 68_100,
    input_tokens: 50_400, output_tokens: 17_700, wall_clock_ms: 4_800_000,
    final_phase: "Ship",
    eval_score: 85, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/102",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 6, eval_lines_changed: 148
  },
  %{
    issue_id: "id-003", issue_identifier: "SYM-103", issue_title: "Normalize API error responses to RFC 7807",
    issue_priority: 3, issue_labels: ["symphony-agent", "enhancement"],
    started_at: hours_ago.(40), finished_at: hours_ago.(39),
    outcome: "completed", agent_backend: "claude", turns_used: 6, total_tokens: 35_600,
    input_tokens: 26_000, output_tokens: 9_600, wall_clock_ms: 2_100_000,
    final_phase: "Ship",
    eval_score: 75, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/103",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: false,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 8, eval_lines_changed: 210
  },
  %{
    issue_id: "id-004", issue_identifier: "SYM-104", issue_title: "Extract rate limiter into standalone GenServer",
    issue_priority: 3, issue_labels: ["symphony-agent", "refactor"],
    started_at: hours_ago.(36), finished_at: hours_ago.(35),
    outcome: "completed", agent_backend: "claude", turns_used: 15, total_tokens: 91_200,
    input_tokens: 67_800, output_tokens: 23_400, wall_clock_ms: 5_400_000,
    final_phase: "Ship",
    eval_score: 95, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/104",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 12, eval_lines_changed: 380
  },
  %{
    issue_id: "id-005", issue_identifier: "SYM-105", issue_title: "Add healthcheck endpoint for k8s probes",
    issue_priority: 2, issue_labels: ["symphony-agent", "enhancement"],
    started_at: hours_ago.(30), finished_at: hours_ago.(29),
    outcome: "completed", agent_backend: "codex", turns_used: 4, total_tokens: 18_900,
    input_tokens: 14_200, output_tokens: 4_700, wall_clock_ms: 1_200_000,
    final_phase: "Ship",
    eval_score: 80, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/105",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: false, eval_tests_written: false, eval_files_changed: 2, eval_lines_changed: 35
  },

  # --- Completed but lower quality ---
  %{
    issue_id: "id-006", issue_identifier: "SYM-106", issue_title: "Fix dark mode toggle not persisting",
    issue_priority: 3, issue_labels: ["symphony-agent", "bug", "frontend"],
    started_at: hours_ago.(26), finished_at: hours_ago.(25),
    outcome: "completed", agent_backend: "codex", turns_used: 10, total_tokens: 55_000,
    input_tokens: 41_000, output_tokens: 14_000, wall_clock_ms: 3_600_000,
    final_phase: "Ship",
    eval_score: 50, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/106",
    eval_ci_status: "failed", eval_branch_pushed: true, eval_evidence_posted: false,
    eval_workpad_updated: true, eval_tests_written: false, eval_files_changed: 3, eval_lines_changed: 28
  },
  %{
    issue_id: "id-007", issue_identifier: "SYM-107", issue_title: "Update onboarding copy for v2 launch",
    issue_priority: 4, issue_labels: ["symphony-agent", "copy"],
    started_at: hours_ago.(22), finished_at: hours_ago.(21),
    outcome: "completed", agent_backend: "claude", turns_used: 3, total_tokens: 12_400,
    input_tokens: 9_200, output_tokens: 3_200, wall_clock_ms: 900_000,
    final_phase: "Ship",
    eval_score: 60, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/107",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: false,
    eval_workpad_updated: false, eval_tests_written: false, eval_files_changed: 5, eval_lines_changed: 44
  },

  # --- Failures ---
  %{
    issue_id: "id-008", issue_identifier: "SYM-108", issue_title: "Migrate user sessions to Redis cluster",
    issue_priority: 1, issue_labels: ["symphony-agent", "enhancement", "infrastructure"],
    started_at: hours_ago.(20), finished_at: hours_ago.(19),
    outcome: "failed", agent_backend: "codex", turns_used: 20, total_tokens: 112_000,
    input_tokens: 84_000, output_tokens: 28_000, wall_clock_ms: 7_200_000,
    final_phase: "Implement",
    error_message: "Agent stalled during Redis cluster configuration", error_category: "stall"
  },
  %{
    issue_id: "id-009", issue_identifier: "SYM-109", issue_title: "Add SAML SSO integration",
    issue_priority: 2, issue_labels: ["symphony-agent", "enhancement"],
    started_at: hours_ago.(16), finished_at: hours_ago.(15),
    outcome: "failed", agent_backend: "claude", turns_used: 18, total_tokens: 98_500,
    input_tokens: 73_000, output_tokens: 25_500, wall_clock_ms: 6_000_000,
    final_phase: "Test",
    error_message: "Tests failed repeatedly; agent exhausted max turns", error_category: "timeout"
  },
  %{
    issue_id: "id-010", issue_identifier: "SYM-110", issue_title: "Implement CSV export for audit logs",
    issue_priority: 3, issue_labels: ["symphony-agent", "enhancement"],
    started_at: hours_ago.(12), finished_at: hours_ago.(11),
    outcome: "failed", agent_backend: "codex", turns_used: 2, total_tokens: 8_200,
    input_tokens: 6_100, output_tokens: 2_100, wall_clock_ms: 420_000,
    final_phase: "Investigate",
    error_message: "Rate limited by upstream API", error_category: "rate_limit"
  },
  %{
    issue_id: "id-011", issue_identifier: "SYM-111", issue_title: "Fix race condition in concurrent job processor",
    issue_priority: 1, issue_labels: ["symphony-agent", "bug"],
    started_at: hours_ago.(8), finished_at: hours_ago.(7),
    outcome: "failed", agent_backend: "claude", turns_used: 14, total_tokens: 76_300,
    input_tokens: 56_800, output_tokens: 19_500, wall_clock_ms: 5_100_000,
    final_phase: "Test",
    error_message: "Process crashed during test execution", error_category: "crash"
  },

  # --- More successes (recent) ---
  %{
    issue_id: "id-012", issue_identifier: "SYM-112", issue_title: "Add request tracing headers to API gateway",
    issue_priority: 2, issue_labels: ["symphony-agent", "enhancement", "infrastructure"],
    started_at: hours_ago.(6), finished_at: hours_ago.(5),
    outcome: "completed", agent_backend: "claude", turns_used: 9, total_tokens: 52_800,
    input_tokens: 39_200, output_tokens: 13_600, wall_clock_ms: 3_000_000,
    final_phase: "Ship",
    eval_score: 85, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/112",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 7, eval_lines_changed: 156
  },
  %{
    issue_id: "id-013", issue_identifier: "SYM-113", issue_title: "Fix timezone handling in scheduled reports",
    issue_priority: 2, issue_labels: ["symphony-agent", "bug"],
    started_at: hours_ago.(4), finished_at: hours_ago.(3),
    outcome: "completed", agent_backend: "codex", turns_used: 7, total_tokens: 38_400,
    input_tokens: 28_600, output_tokens: 9_800, wall_clock_ms: 2_400_000,
    final_phase: "Ship",
    eval_score: 70, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/113",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: false,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 3, eval_lines_changed: 47
  },
  %{
    issue_id: "id-014", issue_identifier: "SYM-114", issue_title: "Refactor notification dispatcher to use Broadway",
    issue_priority: 3, issue_labels: ["symphony-agent", "refactor"],
    started_at: hours_ago.(2), finished_at: hours_ago.(1),
    outcome: "completed", agent_backend: "claude", turns_used: 11, total_tokens: 64_200,
    input_tokens: 47_600, output_tokens: 16_600, wall_clock_ms: 4_200_000,
    final_phase: "Ship",
    eval_score: 88, eval_pr_created: true, eval_pr_url: "https://github.com/openai/symphony/pull/114",
    eval_ci_status: "passed", eval_branch_pushed: true, eval_evidence_posted: true,
    eval_workpad_updated: true, eval_tests_written: true, eval_files_changed: 9, eval_lines_changed: 290
  },

  # --- A failure just now ---
  %{
    issue_id: "id-015", issue_identifier: "SYM-115", issue_title: "Add OpenTelemetry spans to database queries",
    issue_priority: 3, issue_labels: ["symphony-agent", "enhancement", "infrastructure"],
    started_at: hours_ago.(1), finished_at: DateTime.add(now, -1800, :second),
    outcome: "failed", agent_backend: "codex", turns_used: 5, total_tokens: 22_100,
    input_tokens: 16_400, output_tokens: 5_700, wall_clock_ms: 1_800_000,
    final_phase: "Implement",
    error_message: "Failed to spawn agent process", error_category: "spawn_failure"
  }
]

IO.puts("Seeding #{length(runs)} historical runs...")

for attrs <- runs do
  case History.record_dispatch(attrs) do
    {:ok, run} ->
      # If it has a finished_at, also record completion
      if attrs[:finished_at] do
        completion_attrs =
          attrs
          |> Map.take(~w(finished_at outcome turns_used total_tokens input_tokens output_tokens wall_clock_ms final_phase error_message error_category)a)

        {:ok, run} = History.record_completion(run, completion_attrs)

        # If it has eval data, record that too
        if attrs[:eval_score] do
          eval_attrs =
            attrs
            |> Map.take(~w(eval_score eval_pr_created eval_pr_url eval_ci_status eval_files_changed eval_lines_changed eval_branch_pushed eval_evidence_posted eval_workpad_updated eval_tests_written)a)

          {:ok, _run} = History.record_evaluation(run, eval_attrs)
        end
      end

      IO.puts("  ✓ #{attrs.issue_identifier}: #{attrs.issue_title}")

    {:error, changeset} ->
      IO.puts("  ✗ #{attrs.issue_identifier}: #{inspect(changeset.errors)}")
  end
end

IO.puts("\nDone! Seeded #{length(runs)} runs.")
