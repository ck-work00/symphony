defmodule SymphonyElixir.PhaseJudgeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PhaseJudge

  @moduletag :phase_judge

  defp base_entry(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "GEA-2074"
      },
      overrides
    )
  end

  defp eval_result(overrides \\ %{}) do
    Map.merge(
      %{
        pr_created: false,
        pr_url: nil,
        ci_status: "none",
        files_changed: 0,
        lines_changed: 0,
        branch_pushed: false,
        evidence_posted: false,
        workpad_updated: false,
        tests_written: false,
        tester_approved: false,
        plan_posted: false,
        simplify_done: false,
        score: 0
      },
      overrides
    )
  end

  describe "assess/2" do
    test "returns :done when all evidence present" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          tester_approved: true,
          evidence_posted: true,
          simplify_done: true,
          branch_pushed: true
        })

      assert PhaseJudge.assess(entry, eval) == :done
    end

    test "retasks with all phases when no evidence" do
      entry = base_entry()
      eval = eval_result()

      assert {:retask, missing, []} = PhaseJudge.assess(entry, eval)
      assert "Implement" in missing
      assert "Test" in missing
      assert "Share Evidence" in missing
      assert "Simplify" in missing
    end

    test "retasks for Test when PR exists but tester not approved" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Implement" in completed
      assert "Test" in missing
      # Test should be the first missing phase to dispatch next
      assert hd(missing) == "Test"
    end

    test "retasks for Share Evidence after tester approves" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          tester_approved: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Implement" in completed
      assert "Test" in completed
      assert "Share Evidence" in missing
    end

    test "retasks for Simplify when everything except Simplify is done" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          tester_approved: true,
          evidence_posted: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert missing == ["Simplify"]
      assert "Implement" in completed
      assert "Test" in completed
      assert "Share Evidence" in completed
    end

    test "retasks with all phases when eval_result is nil" do
      entry = base_entry()

      assert {:retask, missing, []} = PhaseJudge.assess(entry, nil)
      assert length(missing) == 4
    end

    test "phases_in_order returns canonical list" do
      assert PhaseJudge.phases_in_order() == [
               "Implement",
               "Test",
               "Share Evidence",
               "Simplify"
             ]
    end
  end
end
