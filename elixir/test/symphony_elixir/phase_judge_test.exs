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
          plan_posted: true,
          files_changed: 5,
          pr_created: true,
          tests_written: true,
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
      assert "Investigate" in missing
      assert "Implement" in missing
      assert "Share Evidence" in missing
      assert "Simplify" in missing
    end

    test "retasks for Implement when only plan posted" do
      entry = base_entry()
      eval = eval_result(%{plan_posted: true})

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Investigate" in completed
      assert "Implement" in missing
    end

    test "retasks for Share Evidence when PR exists" do
      entry = base_entry()

      eval =
        eval_result(%{
          plan_posted: true,
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Investigate" in completed
      assert "Implement" in completed
      assert "Share Evidence" in missing
    end

    test "retasks for Simplify when evidence posted" do
      entry = base_entry()

      eval =
        eval_result(%{
          plan_posted: true,
          files_changed: 5,
          pr_created: true,
          tests_written: true,
          evidence_posted: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert missing == ["Simplify"]
      assert "Share Evidence" in completed
    end

    test "retasks with all phases when eval_result is nil" do
      entry = base_entry()

      assert {:retask, missing, []} = PhaseJudge.assess(entry, nil)
      assert length(missing) == 4
    end

    test "phases_in_order returns canonical list" do
      assert PhaseJudge.phases_in_order() == [
               "Investigate",
               "Implement",
               "Share Evidence",
               "Simplify"
             ]
    end
  end
end
