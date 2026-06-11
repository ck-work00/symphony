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

# Allow running against a workflow file outside the checkout (e.g. a
# workspace-owned production config). Falls back to <cwd>/WORKFLOW.md.
if workflow_path = System.get_env("SYMPHONY_WORKFLOW_PATH") do
  config :symphony_elixir, :workflow_file_path, Path.expand(workflow_path)
end
