defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = SymphonyElixir.Repo.configure()
    reap_orphan_tmux_sessions()

    children = [
      SymphonyElixir.Repo,
      SymphonyElixir.Repo.Migrator,
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  # Clean up tmux sessions leaked by a previous run that crashed before its
  # AgentRunner could stop them. Never let this block or fail startup.
  defp reap_orphan_tmux_sessions do
    case SymphonyElixir.Claude.TmuxCLI.reap_orphan_sessions() do
      [] -> :ok
      reaped -> Logger.info("Reaped #{length(reaped)} orphaned Claude tmux session(s): #{inspect(reaped)}")
    end
  rescue
    error -> Logger.warning("Orphan tmux session reap failed: #{Exception.message(error)}")
  end
end
