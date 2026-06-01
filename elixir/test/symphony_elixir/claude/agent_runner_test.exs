defmodule SymphonyElixir.Claude.AgentRunnerTest do
  @moduledoc """
  Drives the refactored turn loop with fake `session_module` / `watcher_module`
  collaborators, so the orchestration (turn sequencing, stop conditions, error
  propagation) is tested without a live tmux/Claude session.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AgentRunner
  alias SymphonyElixir.Linear.Issue

  # --- Fake collaborators ----------------------------------------------------

  defmodule FakeSession do
    @moduledoc false
    def start_session(_workspace, session_id, _opts), do: {:ok, %{session_id: session_id}}

    def send_prompt(_session, _prompt, turn) do
      relay({:sent_prompt, turn})
      Process.get(:fake_send_result, :ok)
    end

    def await_jsonl(_session_id), do: {:ok, "/tmp/fake.jsonl"}
    def stop_session(_session), do: relay(:stopped)

    defp relay(msg) do
      case Application.get_env(:symphony_elixir, :agent_runner_test_pid) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule FakeWatcher do
    @moduledoc false
    def start_link(_opts), do: {:ok, spawn(fn -> :ok end)}

    def wait_for_turn(_watcher, _timeout) do
      case Application.get_env(:symphony_elixir, :fake_wait_result, :ok) do
        :timeout -> {:error, :timeout}
        :ok -> {:ok, %{turn: 0, stop_reason: "end_turn", usage: nil}}
      end
    end

    def stop(_watcher), do: :ok
  end

  # --- Helpers ---------------------------------------------------------------

  defp issue(state) do
    %Issue{id: "issue-1", identifier: "TST-1", title: "Test issue", description: "x", state: state}
  end

  defp base_opts(extra) do
    Keyword.merge(
      [
        session_module: FakeSession,
        watcher_module: FakeWatcher,
        comment_fetcher: fn _id, _after -> {:ok, []} end
      ],
      extra
    )
  end

  setup do
    Application.put_env(:symphony_elixir, :agent_runner_test_pid, self())
    Application.delete_env(:symphony_elixir, :fake_wait_result)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :agent_runner_test_pid)
      Application.delete_env(:symphony_elixir, :fake_wait_result)
      File.rm_rf(Path.join(SymphonyElixir.Config.workspace_root(), "TST-1"))
    end)

    :ok
  end

  defp sent_turns do
    Stream.repeatedly(fn ->
      receive do
        {:sent_prompt, turn} -> turn
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  # --- Tests -----------------------------------------------------------------

  test "stops after max_turns while the issue stays active" do
    opts =
      base_opts(
        max_turns: 3,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    assert sent_turns() == [1, 2, 3]
    assert_received :stopped
  end

  test "stops once the issue reaches a terminal state" do
    opts =
      base_opts(
        max_turns: 10,
        issue_state_fetcher: fn _ids -> {:ok, [issue("Done")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    # Only the first prompt is sent; after turn 1 the issue is terminal.
    assert sent_turns() == [1]
    assert_received :stopped
  end

  test "raises and still stops the session when a turn times out" do
    Application.put_env(:symphony_elixir, :fake_wait_result, :timeout)

    opts =
      base_opts(
        max_turns: 3,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert_raise RuntimeError, fn -> AgentRunner.run(issue("In Progress"), nil, opts) end
    assert sent_turns() == [1]
    assert_received :stopped
  end

  test "raises and stops the session when start_session fails" do
    defmodule FailingSession do
      def start_session(_w, _s, _o), do: {:error, :no_tmux}
      def send_prompt(_s, _p, _t), do: :ok
      def await_jsonl(_s), do: {:ok, "/tmp/x.jsonl"}
      def stop_session(_s), do: :ok
    end

    opts =
      base_opts(
        session_module: FailingSession,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert_raise RuntimeError, fn -> AgentRunner.run(issue("In Progress"), nil, opts) end
  end
end
