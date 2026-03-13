defmodule SymphonyElixir.HistoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.History
  alias SymphonyElixir.History.Run
  alias SymphonyElixir.Repo

  @moduletag :history

  setup_all do
    # The Application starts the Repo with the configured database.
    # Run migrations to ensure tables exist (idempotent).
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM run_events")
    Repo.query!("DELETE FROM runs")
    :ok
  end

  describe "record_dispatch/1" do
    test "inserts a run record" do
      attrs = dispatch_attrs()

      assert {:ok, %Run{} = run} = History.record_dispatch(attrs)
      assert run.issue_identifier == "SYM-42"
      assert run.issue_id == "linear-uuid-1"
      assert run.agent_backend == "claude"
      assert is_binary(run.id)
    end

    test "rejects missing required fields" do
      assert {:error, _changeset} = History.record_dispatch(%{})
    end
  end

  describe "record_completion/2" do
    test "updates a run with completion data" do
      {:ok, run} = History.record_dispatch(dispatch_attrs())

      completion = %{
        finished_at: DateTime.utc_now(),
        outcome: "completed",
        turns_used: 3,
        input_tokens: 50_000,
        output_tokens: 10_000,
        total_tokens: 60_000,
        wall_clock_ms: 120_000,
        final_phase: "ship"
      }

      assert {:ok, %Run{} = updated} = History.record_completion(run, completion)
      assert updated.outcome == "completed"
      assert updated.turns_used == 3
      assert updated.total_tokens == 60_000
    end

    test "returns error for nonexistent run ID" do
      assert {:error, :not_found} =
               History.record_completion(Ecto.UUID.generate(), %{outcome: "completed"})
    end
  end

  describe "record_evaluation/2" do
    test "updates eval fields on a run" do
      {:ok, run} = History.record_dispatch(dispatch_attrs())

      eval = %{
        eval_score: 85,
        eval_pr_created: true,
        eval_pr_url: "https://github.com/org/repo/pull/1",
        eval_ci_status: "passed",
        eval_files_changed: 5,
        eval_lines_changed: 120,
        eval_branch_pushed: true,
        eval_evidence_posted: true,
        eval_workpad_updated: true,
        eval_tests_written: true
      }

      assert {:ok, %Run{} = updated} = History.record_evaluation(run, eval)
      assert updated.eval_score == 85
      assert updated.eval_pr_created == true
      assert updated.eval_ci_status == "passed"
    end
  end

  describe "list_runs/1" do
    test "returns runs ordered by started_at desc" do
      t1 = ~U[2026-03-01 10:00:00.000000Z]
      t2 = ~U[2026-03-02 10:00:00.000000Z]

      {:ok, _} = History.record_dispatch(dispatch_attrs(started_at: t1, issue_identifier: "SYM-1"))
      {:ok, _} = History.record_dispatch(dispatch_attrs(started_at: t2, issue_identifier: "SYM-2"))

      runs = History.list_runs()
      assert length(runs) == 2
      assert hd(runs).issue_identifier == "SYM-2"
    end

    test "filters by outcome" do
      {:ok, run1} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-1"))
      {:ok, _run2} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-2"))

      History.record_completion(run1, %{finished_at: DateTime.utc_now(), outcome: "completed"})

      completed = History.list_runs(outcome: "completed")
      assert length(completed) == 1
      assert hd(completed).issue_identifier == "SYM-1"
    end
  end

  describe "runs_for_issue/1" do
    test "returns all runs for a specific issue" do
      {:ok, _} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-42"))
      {:ok, _} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-42"))
      {:ok, _} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-99"))

      runs = History.runs_for_issue("SYM-42")
      assert length(runs) == 2
    end
  end

  describe "success_rate/1" do
    test "computes percentage of completed runs" do
      {:ok, r1} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-1"))
      {:ok, r2} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-2"))
      {:ok, r3} = History.record_dispatch(dispatch_attrs(issue_identifier: "SYM-3"))

      History.record_completion(r1, %{finished_at: DateTime.utc_now(), outcome: "completed"})
      History.record_completion(r2, %{finished_at: DateTime.utc_now(), outcome: "completed"})
      History.record_completion(r3, %{finished_at: DateTime.utc_now(), outcome: "failed"})

      rate = History.success_rate()
      assert_in_delta rate, 66.67, 0.1
    end

    test "returns 0.0 when no completed runs" do
      assert History.success_rate() == 0.0
    end
  end

  describe "record_event/1" do
    test "inserts a run event" do
      {:ok, run} = History.record_dispatch(dispatch_attrs())

      assert {:ok, event} =
               History.record_event(%{
                 run_id: run.id,
                 event_type: "phase_change",
                 payload: %{"from" => "investigate", "to" => "implement"},
                 timestamp: DateTime.utc_now()
               })

      assert event.event_type == "phase_change"
    end
  end

  describe "events_for_run/1" do
    test "returns events ordered by timestamp" do
      {:ok, run} = History.record_dispatch(dispatch_attrs())

      t1 = ~U[2026-03-01 10:00:00.000000Z]
      t2 = ~U[2026-03-01 11:00:00.000000Z]

      History.record_event(%{run_id: run.id, event_type: "phase_change", timestamp: t2})
      History.record_event(%{run_id: run.id, event_type: "retry", timestamp: t1})

      events = History.events_for_run(run.id)
      assert length(events) == 2
      assert hd(events).event_type == "retry"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp dispatch_attrs(overrides \\ []) do
    Enum.into(overrides, %{
      issue_id: "linear-uuid-1",
      issue_identifier: "SYM-42",
      issue_title: "Fix the thing",
      issue_priority: 2,
      issue_labels: ["bug", "symphony"],
      started_at: DateTime.utc_now(),
      agent_backend: "claude",
      project_slug: "test-project"
    })
  end

  defp migrations_path do
    Path.join([__DIR__, "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end
end
