defmodule SymphonyElixir.Claude.SessionWatcherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.SessionWatcher

  setup do
    path =
      Path.join(System.tmp_dir!(), "session-watcher-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp start_watcher(path, opts \\ []) do
    test = self()
    on_event = Keyword.get(opts, :on_event, fn e -> send(test, {:event, e}) end)

    {:ok, pid} =
      SessionWatcher.start_link(
        jsonl_path: path,
        on_event: on_event,
        poll_interval_ms: 10
      )

    on_exit(fn -> if Process.alive?(pid), do: SessionWatcher.stop(pid) end)
    pid
  end

  defp append(path, line), do: File.write!(path, line <> "\n", [:append])

  defp assistant(stop_reason, opts \\ []) do
    Jason.encode!(%{
      "type" => "assistant",
      "isSidechain" => Keyword.get(opts, :sidechain, false),
      "message" => %{
        "stop_reason" => stop_reason,
        "usage" => Keyword.get(opts, :usage, %{"input_tokens" => 1, "output_tokens" => 5})
      }
    })
  end

  test "fires on_event for every parsed event", %{path: path} do
    pid = start_watcher(path)
    append(path, ~s({"type":"system","subtype":"init","session_id":"abc"}))
    append(path, assistant("end_turn"))

    assert_receive {:event, %{event_type: :session_started}}, 1_000
    assert_receive {:event, %{event_type: :assistant}}, 1_000
    assert SessionWatcher.completed_turns(pid) == 1
  end

  test "wait_for_turn returns the summary of a completed main-chain turn", %{path: path} do
    pid = start_watcher(path)
    append(path, assistant("tool_use"))
    append(path, assistant("end_turn", usage: %{"input_tokens" => 1, "cache_read_input_tokens" => 100, "output_tokens" => 5}))

    assert {:ok, summary} = SessionWatcher.wait_for_turn(pid, 1_000)
    assert summary.turn == 1
    assert summary.stop_reason == "end_turn"
    # 1 input + 100 cache_read folded into effective input, 5 output.
    assert summary.usage == %{input_tokens: 101, output_tokens: 5, total_tokens: 106}
  end

  test "tool_use messages do not complete a turn", %{path: path} do
    pid = start_watcher(path)
    append(path, assistant("tool_use"))
    append(path, assistant("tool_use"))
    Process.sleep(60)
    assert SessionWatcher.completed_turns(pid) == 0
    assert {:error, :timeout} = SessionWatcher.wait_for_turn(pid, 50)
  end

  test "subagent (sidechain) end_turn does not complete the parent turn", %{path: path} do
    pid = start_watcher(path)
    append(path, assistant("tool_use"))
    append(path, assistant("end_turn", sidechain: true))
    Process.sleep(60)
    assert SessionWatcher.completed_turns(pid) == 0

    append(path, assistant("end_turn"))
    assert {:ok, %{turn: 1}} = SessionWatcher.wait_for_turn(pid, 1_000)
  end

  test "tracks multiple turns in sequence", %{path: path} do
    pid = start_watcher(path)
    append(path, assistant("end_turn"))
    assert {:ok, %{turn: 1}} = SessionWatcher.wait_for_turn(pid, 1_000)

    append(path, assistant("tool_use"))
    append(path, assistant("end_turn"))
    assert {:ok, %{turn: 2}} = SessionWatcher.wait_for_turn(pid, 1_000)
  end

  test "wait_for_turn times out when no end_turn arrives", %{path: path} do
    pid = start_watcher(path)
    assert {:error, :timeout} = SessionWatcher.wait_for_turn(pid, 50)
  end

  test "holds a partial line until the newline arrives", %{path: path} do
    start_watcher(path)
    line = ~s({"type":"system","subtype":"init","session_id":"xyz"})
    {first, second} = String.split_at(line, 15)

    File.write!(path, first, [:append])
    refute_receive {:event, _}, 60

    File.write!(path, second <> "\n", [:append])
    assert_receive {:event, %{event_type: :session_started}}, 1_000
  end
end
