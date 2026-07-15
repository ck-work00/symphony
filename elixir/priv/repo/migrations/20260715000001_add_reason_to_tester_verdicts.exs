defmodule SymphonyElixir.Repo.Migrations.AddReasonToTesterVerdicts do
  use Ecto.Migration

  def change do
    alter table(:tester_verdicts) do
      add(:reason, :text)
    end
  end
end
