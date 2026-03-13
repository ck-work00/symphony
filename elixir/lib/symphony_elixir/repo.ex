defmodule SymphonyElixir.Repo do
  @moduledoc """
  Ecto repo backed by SQLite for persisting run history and metrics.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @default_db_path "~/.symphony/symphony.db"

  @doc """
  Returns the database path, expanding `~` and ensuring the parent directory exists.
  """
  @spec database_path() :: String.t()
  def database_path do
    path =
      Application.get_env(:symphony_elixir, __MODULE__, [])
      |> Keyword.get(:database, @default_db_path)
      |> Path.expand()

    path |> Path.dirname() |> File.mkdir_p!()
    path
  end

  @doc """
  Configures the repo at runtime with the resolved database path.
  Called before the repo starts in the supervision tree.
  """
  @spec configure() :: :ok
  def configure do
    db_path = database_path()

    config =
      Application.get_env(:symphony_elixir, __MODULE__, [])
      |> Keyword.put(:database, db_path)

    Application.put_env(:symphony_elixir, __MODULE__, config)
    :ok
  end
end
