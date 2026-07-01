defmodule SymphonyElixir.Repo.Migrations.CreateTesterVerdicts do
  use Ecto.Migration

  def change do
    create table(:tester_verdicts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_identifier, :string, null: false

      # APPROVE | REQUEST_CHANGES | BLOCKED — the machine-readable tester verdict,
      # captured from the tester's SYMPHONY_VERDICT marker in its output stream.
      # This is the machine source of truth; the Linear report is for humans.
      add :verdict, :string, null: false

      # The PR head the tester actually tested (if it reported one), so a verdict
      # can be matched to the commit it verified.
      add :commit_sha, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tester_verdicts, [:issue_identifier, :inserted_at])
  end
end
