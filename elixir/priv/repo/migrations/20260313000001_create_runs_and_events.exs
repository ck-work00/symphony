defmodule SymphonyElixir.Repo.Migrations.CreateRunsAndEvents do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Issue context
      add :issue_id, :string, null: false
      add :issue_identifier, :string, null: false
      add :issue_title, :string
      add :issue_priority, :integer
      add :issue_labels, {:array, :string}, default: []

      # Targeting context
      add :filter_source, :string
      add :project_slug, :string

      # Run lifecycle
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :outcome, :string
      add :agent_backend, :string
      add :session_id, :string
      add :workspace_path, :string

      # Effort
      add :turns_used, :integer, default: 0
      add :retry_attempt, :integer, default: 0
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :wall_clock_ms, :integer

      # Phase reached
      add :final_phase, :string

      # Evaluation
      add :eval_score, :integer
      add :eval_pr_created, :boolean
      add :eval_pr_url, :string
      add :eval_ci_status, :string
      add :eval_files_changed, :integer
      add :eval_lines_changed, :integer
      add :eval_branch_pushed, :boolean
      add :eval_evidence_posted, :boolean
      add :eval_workpad_updated, :boolean
      add :eval_tests_written, :boolean

      # Error context
      add :error_message, :string
      add :error_category, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:issue_identifier])
    create index(:runs, [:outcome])
    create index(:runs, [:started_at])
    create index(:runs, [:eval_score])

    create table(:run_events) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, default: %{}
      add :timestamp, :utc_datetime_usec, null: false
    end

    create index(:run_events, [:run_id])
  end
end
