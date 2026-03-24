defmodule SymphonyElixir.Repo.Migrations.AddEscalationFieldsToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :escalation_type, :string
      add :escalated_at, :utc_datetime_usec
      add :needs_human, :boolean, default: false
      add :needs_human_message, :string
    end
  end
end
