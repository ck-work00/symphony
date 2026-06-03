import Config

# Runtime config for Mix releases.
# This file is evaluated at boot time (not compile time) and overrides the
# compile-time config, so it must also keep :test on a separate DB — otherwise
# `mix test` (which resets the runs table) would wipe the dev/prod database.

db_path =
  if config_env() == :test,
    do: "~/.symphony/symphony_test.db",
    else: "~/.symphony/symphony.db"

config :symphony_elixir, SymphonyElixir.Repo,
  database: Path.expand(db_path),
  pool_size: 1,
  journal_mode: :wal
