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
          pr_url: "https://github.com/org/repo/pull/42",
          tests_written: true,
          evidence_posted: true,
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
      assert "Test" in missing
      assert "Ship" in missing
      assert "Share Evidence" in missing
    end

    test "retasks for Test and Share Evidence when PR exists but no tests or evidence" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 3,
          pr_created: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Investigate" in completed
      assert "Implement" in completed
      assert "Ship" in completed
      assert "Test" in missing
      assert "Share Evidence" in missing
    end

    test "retasks for Share Evidence when tests written but no evidence posted" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 3,
          pr_created: true,
          tests_written: true,
          branch_pushed: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert missing == ["Share Evidence"]
      assert "Test" in completed
    end

    test "retasks for Ship when code changes exist but no PR" do
      entry = base_entry()

      eval =
        eval_result(%{
          files_changed: 3,
          tests_written: true,
          evidence_posted: true
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry, eval)
      assert "Ship" in missing
      refute "Ship" in completed
    end

    test "retasks with all phases when eval_result is nil" do
      entry = base_entry()

      assert {:retask, missing, []} = PhaseJudge.assess(entry, nil)
      assert length(missing) == 5
    end

    test "phases_in_order returns canonical list" do
      assert PhaseJudge.phases_in_order() == [
               "Investigate",
               "Implement",
               "Test",
               "Ship",
               "Share Evidence"
             ]
    end
  end
end
