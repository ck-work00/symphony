import Config

config :phoenix, :json_library, Jason

db_filename = if config_env() == :test, do: "symphony_test.db", else: "symphony.db"

config :symphony_elixir, SymphonyElixir.Repo,
  database: Path.expand(db_filename),
  pool_size: 1,
  journal_mode: :wal

config :symphony_elixir,
  ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
