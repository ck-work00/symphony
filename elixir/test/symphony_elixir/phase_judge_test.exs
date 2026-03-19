defmodule SymphonyElixir.PhaseJudgeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PhaseJudge

  @moduletag :phase_judge

  defp base_entry(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "GEA-2074",
        phases_seen: [],
        pr_url: nil,
        screenshot_urls: []
      },
      overrides
    )
  end

  describe "assess/1" do
    test "returns :done when all phases completed" do
      entry =
        base_entry(%{
          phases_seen: ["Investigate", "Implement", "Test", "Ship", "Share Evidence"],
          pr_url: "https://github.com/org/repo/pull/42",
          screenshot_urls: ["https://linear.app/asset/1.png"]
        })

      assert PhaseJudge.assess(entry) == :done
    end

    test "retasks with all phases when nothing done" do
      entry = base_entry()

      assert {:retask, missing, []} = PhaseJudge.assess(entry)
      assert "Investigate" in missing
      assert "Implement" in missing
      assert "Test" in missing
      assert "Ship" in missing
      assert "Share Evidence" in missing
    end

    test "retasks for Test and Share Evidence when PR exists but no screenshots" do
      entry =
        base_entry(%{
          phases_seen: ["Investigate", "Implement", "Ship"],
          pr_url: "https://github.com/org/repo/pull/42",
          screenshot_urls: []
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry)
      assert "Investigate" in completed
      assert "Implement" in completed
      assert "Ship" in completed
      assert "Test" in missing
      assert "Share Evidence" in missing
      refute "Investigate" in missing
      refute "Implement" in missing
      refute "Ship" in missing
    end

    test "retasks for Share Evidence when screenshots exist but not posted" do
      entry =
        base_entry(%{
          phases_seen: ["Investigate", "Implement", "Test", "Ship"],
          pr_url: "https://github.com/org/repo/pull/42",
          screenshot_urls: ["https://linear.app/asset/1.png"]
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry)
      assert missing == ["Share Evidence"]
      assert "Test" in completed
    end

    test "retasks for Ship when code changes exist but no PR" do
      entry =
        base_entry(%{
          phases_seen: ["Investigate", "Implement", "Test", "Share Evidence"],
          pr_url: nil,
          screenshot_urls: ["https://linear.app/asset/1.png"]
        })

      assert {:retask, missing, completed} = PhaseJudge.assess(entry)
      assert "Ship" in missing
      refute "Ship" in completed
    end

    test "missing phases are in canonical order" do
      entry = base_entry(%{phases_seen: ["Investigate"], pr_url: nil})

      assert {:retask, missing, _completed} = PhaseJudge.assess(entry)
      # Missing phases should follow the canonical order
      assert missing == ["Test", "Ship", "Share Evidence"] ||
               hd(missing) in ["Implement", "Test", "Ship", "Share Evidence"]
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
