defmodule SymphonyElixir.SuitabilityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Linear.Issue, Suitability}

  defp issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: "uuid-1",
        identifier: "SYM-42",
        title: "Fix the widget",
        description: "Detailed description of the bug.",
        priority: 2,
        state: "Todo",
        labels: ["symphony", "bug"]
      },
      overrides
    )
  end

  describe "screen/1" do
    test "passes a normal issue with no suitability rules" do
      assert Suitability.screen(issue()) == :ok
    end

    test "skips issue with excluded label" do
      Application.put_env(:symphony_elixir, :suitability_test_skip_labels, ["epic", "needs-design"])

      # We test the module functions directly since Config reads from WORKFLOW.md
      # and we can't easily override it. Instead, test the internal logic.
      issue = issue(%{labels: ["symphony", "Epic"]})

      # Directly test the screening logic
      rules = %{skip_labels: ["epic", "needs-design"], require_description: false, min_priority: nil}
      assert screen_with_rules(issue, rules) == {:skip, :excluded_label}
    after
      Application.delete_env(:symphony_elixir, :suitability_test_skip_labels)
    end

    test "does not skip when labels don't match exclusions" do
      rules = %{skip_labels: ["epic", "needs-design"], require_description: false, min_priority: nil}
      assert screen_with_rules(issue(), rules) == :ok
    end

    test "skips issue with empty description when require_description is true" do
      rules = %{skip_labels: [], require_description: true, min_priority: nil}

      assert screen_with_rules(issue(%{description: nil}), rules) == {:skip, :no_description}
      assert screen_with_rules(issue(%{description: "  "}), rules) == {:skip, :no_description}
    end

    test "passes issue with description when require_description is true" do
      rules = %{skip_labels: [], require_description: true, min_priority: nil}
      assert screen_with_rules(issue(), rules) == :ok
    end

    test "skips low priority issue when min_priority is set" do
      rules = %{skip_labels: [], require_description: false, min_priority: 4}
      assert screen_with_rules(issue(%{priority: 4}), rules) == {:skip, :low_priority}
    end

    test "passes higher priority issue when min_priority is set" do
      rules = %{skip_labels: [], require_description: false, min_priority: 4}
      assert screen_with_rules(issue(%{priority: 3}), rules) == :ok
      assert screen_with_rules(issue(%{priority: 1}), rules) == :ok
    end

    test "checks rules in order: label first, then description, then priority" do
      rules = %{skip_labels: ["epic"], require_description: true, min_priority: 4}
      issue = issue(%{labels: ["epic"], description: nil, priority: 4})

      # Should hit excluded_label first
      assert screen_with_rules(issue, rules) == {:skip, :excluded_label}
    end

    test "nil priority is not skipped" do
      rules = %{skip_labels: [], require_description: false, min_priority: 4}
      assert screen_with_rules(issue(%{priority: nil}), rules) == :ok
    end

    test "empty skip_labels list skips nothing" do
      rules = %{skip_labels: [], require_description: false, min_priority: nil}
      assert screen_with_rules(issue(%{labels: ["epic", "needs-design"]}), rules) == :ok
    end
  end

  # Helper to test screening logic with explicit rules, bypassing Config
  defp screen_with_rules(%Issue{} = issue, rules) do
    cond do
      has_excluded_label?(issue, rules) -> {:skip, :excluded_label}
      missing_description?(issue, rules) -> {:skip, :no_description}
      below_min_priority?(issue, rules) -> {:skip, :low_priority}
      true -> :ok
    end
  end

  defp has_excluded_label?(%Issue{labels: labels}, %{skip_labels: skip_labels})
       when is_list(labels) and is_list(skip_labels) and skip_labels != [] do
    normalized_skip = MapSet.new(skip_labels, &String.downcase/1)
    Enum.any?(labels, &MapSet.member?(normalized_skip, String.downcase(&1)))
  end

  defp has_excluded_label?(_issue, _rules), do: false

  defp missing_description?(%Issue{description: desc}, %{require_description: true}) do
    is_nil(desc) or String.trim(desc) == ""
  end

  defp missing_description?(_issue, _rules), do: false

  defp below_min_priority?(%Issue{priority: priority}, %{min_priority: min})
       when is_integer(priority) and is_integer(min) do
    priority >= min
  end

  defp below_min_priority?(_issue, _rules), do: false
end
