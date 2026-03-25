defmodule SymphonyElixir.Linear.FilterBuilderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.FilterBuilder

  describe "build/2" do
    test "builds label include filter" do
      filter = FilterBuilder.build(%{labels: %{include: ["symphony", "bug"]}})
      assert filter == %{"labels" => %{"name" => %{"in" => ["symphony", "bug"]}}}
    end

    test "bare label list treated as include" do
      filter = FilterBuilder.build(%{labels: ["symphony"]})
      assert filter == %{"labels" => %{"name" => %{"in" => ["symphony"]}}}
    end

    test "builds team filter" do
      filter = FilterBuilder.build(%{teams: ["ENG", "PLATFORM"]})
      assert filter == %{"team" => %{"key" => %{"in" => ["ENG", "PLATFORM"]}}}
    end

    test "builds priority max filter" do
      filter = FilterBuilder.build(%{priority: %{max: 3}})
      assert filter == %{"priority" => %{"lte" => 3}}
    end

    test "builds priority min filter" do
      filter = FilterBuilder.build(%{priority: %{min: 1}})
      assert filter == %{"priority" => %{"gte" => 1}}
    end

    test "combines multiple filters with AND" do
      filter = FilterBuilder.build(%{labels: ["symphony"], teams: ["ENG"]})

      assert %{"and" => conditions} = filter
      assert length(conditions) == 2

      assert Enum.any?(conditions, fn c ->
               c == %{"labels" => %{"name" => %{"in" => ["symphony"]}}}
             end)

      assert Enum.any?(conditions, fn c ->
               c == %{"team" => %{"key" => %{"in" => ["ENG"]}}}
             end)
    end

    test "adds state filter when state_names provided" do
      filter = FilterBuilder.build(%{labels: ["symphony"]}, ["Todo", "In Progress"])

      assert %{"and" => conditions} = filter

      assert Enum.any?(conditions, fn c ->
               c == %{"state" => %{"name" => %{"in" => ["Todo", "In Progress"]}}}
             end)
    end

    test "label exclude adds NOT conditions" do
      filter = FilterBuilder.build(%{labels: %{include: ["symphony"], exclude: ["epic", "needs-design"]}})

      # Should have the include filter AND two exclude conditions
      assert %{"and" => conditions} = filter

      assert Enum.any?(conditions, fn c ->
               c == %{"labels" => %{"name" => %{"in" => ["symphony"]}}}
             end)

      assert Enum.any?(conditions, fn c ->
               c == %{"labels" => %{"name" => %{"neq" => "epic"}}}
             end)

      assert Enum.any?(conditions, fn c ->
               c == %{"labels" => %{"name" => %{"neq" => "needs-design"}}}
             end)
    end

    test "returns empty map when no filters" do
      assert FilterBuilder.build(%{}) == %{}
    end

    test "handles string label keys" do
      filter = FilterBuilder.build(%{"labels" => %{"include" => ["symphony"]}})
      assert filter == %{"labels" => %{"name" => %{"in" => ["symphony"]}}}
    end
  end

  describe "valid?/1" do
    test "true when labels include is set" do
      assert FilterBuilder.valid?(%{labels: ["symphony"]})
    end

    test "true when labels include map is set" do
      assert FilterBuilder.valid?(%{labels: %{include: ["symphony"]}})
    end

    test "true when teams is set" do
      assert FilterBuilder.valid?(%{teams: ["ENG"]})
    end

    test "false when empty" do
      refute FilterBuilder.valid?(%{})
    end

    test "false when only priority (needs at least project, labels, or team)" do
      refute FilterBuilder.valid?(%{priority: %{max: 3}})
    end

    test "false for non-map" do
      refute FilterBuilder.valid?(nil)
      refute FilterBuilder.valid?("string")
    end
  end
end
