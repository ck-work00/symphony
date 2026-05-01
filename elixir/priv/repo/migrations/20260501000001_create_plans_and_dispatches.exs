defmodule SymphonyElixir.Repo.Migrations.CreatePlansAndDispatches do
  use Ecto.Migration

  def change do
    create table(:plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Issue context
      add :issue_id, :string, null: false
      add :issue_identifier, :string, null: false

      # Lifecycle status: planning | dispatching | grading | done | failed
      add :status, :string, null: false, default: "planning"

      # Structured plan body — list of rows with id, description, file/test hints, deps, state.
      # Stored as a JSON map; SQLite holds it as TEXT.
      add :plan_json, :map, default: %{}

      # Linear comment that mirrors the plan, edited in place as state changes.
      add :linear_comment_id, :string

      # Plan-level metadata: model used, prompt version, audit summary if a WIP branch existed.
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plans, [:issue_identifier])
    create index(:plans, [:status])

    create table(:plan_dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :plan_id, references(:plans, type: :binary_id, on_delete: :delete_all), null: false

      # Optional FK to runs — populated once the worker dispatch produces a run row.
      # Not enforced as a real FK because run rows can be deleted independently.
      add :run_id, :binary_id

      add :slot_name, :string
      add :role, :string, null: false, default: "implement"
      # role values: implement | test | regrade

      # Rows assigned to this dispatch (subset of plan_json.rows).
      add :assigned_rows_json, :map, default: %{}

      # Grader output: per-row ✅/⚠/❌ + rationale, plus aggregate APPROVE / REQUEST_CHANGES.
      add :grade_json, :map

      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plan_dispatches, [:plan_id])
    create index(:plan_dispatches, [:run_id])
    create index(:plan_dispatches, [:role])
  end
end
