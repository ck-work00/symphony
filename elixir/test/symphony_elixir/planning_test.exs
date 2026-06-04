defmodule SymphonyElixir.PlanningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Dispatch}
  alias SymphonyElixir.Repo

  @moduletag :planning

  setup_all do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM plan_dispatches")
    Repo.query!("DELETE FROM plans")
    :ok
  end

  defp migrations_path do
    Path.join([Application.app_dir(:symphony_elixir), "..", "..", "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end

  defp plan_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "linear-uuid-1",
        issue_identifier: "SYM-1",
        plan_json: %{
          "rows" => [
            %{"id" => "R1", "description" => "First row", "state" => "missing"},
            %{"id" => "R2", "description" => "Second row", "state" => "partial", "rationale" => "stub exists"}
          ]
        }
      },
      overrides
    )
  end

  describe "upsert_plan/1" do
    test "inserts a new plan when none exists for the issue" do
      assert {:ok, %Plan{} = plan} = Planning.upsert_plan(plan_attrs())
      assert plan.issue_identifier == "SYM-1"
      assert plan.status == "planning"
      assert length(plan.plan_json["rows"]) == 2
    end

    test "updates an existing plan when called twice for the same issue" do
      assert {:ok, %Plan{id: id1}} = Planning.upsert_plan(plan_attrs())

      updated_attrs =
        plan_attrs(%{
          status: "dispatching",
          plan_json: %{"rows" => [%{"id" => "R1", "description" => "First row", "state" => "done"}]}
        })

      assert {:ok, %Plan{id: id2} = plan} = Planning.upsert_plan(updated_attrs)
      assert id1 == id2
      assert plan.status == "dispatching"
      assert hd(plan.plan_json["rows"])["state"] == "done"
    end
  end

  describe "open_rows/1" do
    test "returns rows in `missing` or `partial` state" do
      {:ok, plan} = Planning.upsert_plan(plan_attrs())
      open = Plan.open_rows(plan)
      assert length(open) == 2
      assert Enum.map(open, & &1["id"]) == ["R1", "R2"]
    end

    test "excludes rows in `done` or `deferred` state" do
      attrs =
        plan_attrs(%{
          plan_json: %{
            "rows" => [
              %{"id" => "R1", "description" => "First", "state" => "done"},
              %{"id" => "R2", "description" => "Second", "state" => "missing"},
              %{"id" => "R3", "description" => "Third", "state" => "deferred"}
            ]
          }
        })

      {:ok, plan} = Planning.upsert_plan(attrs)
      assert Plan.open_rows(plan) |> Enum.map(& &1["id"]) == ["R2"]
    end
  end

  describe "replace_rows/2" do
    test "swaps the rows array while preserving other plan_json keys" do
      attrs =
        plan_attrs(%{
          plan_json: %{
            "rows" => [%{"id" => "R1", "description" => "x", "state" => "missing"}],
            "notes" => "preserve me"
          }
        })

      {:ok, plan} = Planning.upsert_plan(attrs)

      new_rows = [%{"id" => "R1", "description" => "x", "state" => "done", "rationale" => "shipped"}]
      assert {:ok, updated} = Planning.replace_rows(plan, new_rows)
      assert hd(updated.plan_json["rows"])["state"] == "done"
      assert updated.plan_json["notes"] == "preserve me"
    end
  end

  describe "record_dispatch/1 and record_grade/2" do
    test "creates a dispatch row tied to a plan and grades it later" do
      {:ok, plan} = Planning.upsert_plan(plan_attrs())

      assigned = %{"rows" => [%{"id" => "R1", "description" => "First row"}]}

      assert {:ok, %Dispatch{} = dispatch} =
               Planning.record_dispatch(%{
                 plan_id: plan.id,
                 role: "implement",
                 slot_name: "procurement-5",
                 assigned_rows_json: assigned,
                 started_at: DateTime.utc_now()
               })

      assert dispatch.role == "implement"
      assert dispatch.slot_name == "procurement-5"
      assert dispatch.grade_json == nil

      grade = %{
        "verdict" => "approve",
        "rationale" => "implementation matches spec",
        "rows" => [%{"id" => "R1", "state" => "done", "note" => "lib/x.ex:42"}]
      }

      assert {:ok, graded} = Planning.record_grade(dispatch, grade)
      assert graded.grade_json["verdict"] == "approve"
      assert graded.finished_at != nil
    end
  end

  describe "dispatches_for_plan/1" do
    test "returns dispatches in insertion order" do
      {:ok, plan} = Planning.upsert_plan(plan_attrs())

      {:ok, d1} =
        Planning.record_dispatch(%{plan_id: plan.id, role: "implement", slot_name: "a"})

      Process.sleep(10)

      {:ok, d2} =
        Planning.record_dispatch(%{plan_id: plan.id, role: "regrade", slot_name: "b"})

      assert [first, second] = Planning.dispatches_for_plan(plan)
      assert first.id == d1.id
      assert second.id == d2.id
    end
  end
end
