defmodule SymphonyElixir.History.TesterVerdict do
  @moduledoc """
  A tester's verdict, recorded to the DB (the machine source of truth) from the
  `SYMPHONY_VERDICT` marker the tester emits in its output stream. The tester
  also posts a human-readable report to Linear, but the orchestrator's gate
  reads this record — free-text on a Linear comment is for people, not control
  flow.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @verdicts ~w(APPROVE REQUEST_CHANGES BLOCKED)

  @type t :: %__MODULE__{}

  schema "tester_verdicts" do
    field(:issue_identifier, :string)
    field(:verdict, :string)
    field(:commit_sha, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:issue_identifier, :verdict, :commit_sha])
    |> validate_required([:issue_identifier, :verdict])
    |> validate_inclusion(:verdict, @verdicts)
  end
end
