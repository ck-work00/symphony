defmodule SymphonyElixir.Claude.SessionWatcher do
  @moduledoc """
  Tails a Claude Code session JSONL file and turns it into a live event stream.

  Interactive Claude Code writes the full structured event stream — the same
  events `claude -p --output-format stream-json` emits, plus extra metadata — to
  a per-session JSONL file. `SymphonyElixir.Claude.TmuxCLI` hosts the session;
  this GenServer is its event source, replacing the stdout pipe that
  `SymphonyElixir.Claude.CLI` read.

  Responsibilities:

    * Poll-tail the append-only JSONL, parse each line with
      `SymphonyElixir.Claude.StreamParser`, and invoke `on_event` for every event
      (so the dashboard sees the same stream as before).
    * Detect turn boundaries so the agent runner can drive one prompt per turn.

  ## Turn boundaries

  A submitted prompt produces a chain of assistant messages; the final one carries
  `stop_reason` `"end_turn"` (or `"stop_sequence"`). Intermediate tool-use messages
  carry `"tool_use"`, so the terminal message is unambiguous. Subagents (the
  `Agent` tool) write their own messages into the same file with
  `isSidechain: true` and their own `end_turn` — those are filtered out, otherwise
  a subagent finishing mid-turn would look like the turn ending.

  Each main-chain `end_turn` increments a completed-turn counter. `wait_for_turn/2`
  returns the summary (usage + stop reason) for the next turn in sequence, blocking
  until it arrives or the timeout elapses. Counting in order — rather than matching
  a user-message UUID we can't know at paste time — is robust to the watcher
  lagging behind the writer.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Config

  @type turn_summary :: %{turn: pos_integer(), stop_reason: String.t() | nil, usage: map() | nil}

  # --- Public API ------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Block until the next turn (in sequence) completes, returning its summary.

  Returns `{:error, :timeout}` if no main-chain `end_turn` arrives within
  `timeout_ms`.
  """
  @spec wait_for_turn(GenServer.server(), timeout()) :: {:ok, turn_summary()} | {:error, :timeout}
  def wait_for_turn(server, timeout_ms) do
    # :infinity here — the watcher itself enforces timeout_ms and replies.
    GenServer.call(server, {:wait_for_turn, timeout_ms}, :infinity)
  end

  @doc "Number of completed (main-chain `end_turn`) turns seen so far."
  @spec completed_turns(GenServer.server()) :: non_neg_integer()
  def completed_turns(server), do: GenServer.call(server, :completed_turns)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    jsonl_path = Keyword.fetch!(opts, :jsonl_path)
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, Config.claude_tmux_jsonl_poll_interval_ms())

    state = %{
      path: jsonl_path,
      offset: 0,
      buffer: "",
      on_event: on_event,
      poll_ms: poll_ms,
      completed_turns: 0,
      awaited_turns: 0,
      summaries: %{},
      waiters: []
    }

    schedule_poll(poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:wait_for_turn, timeout_ms}, from, state) do
    target = state.awaited_turns + 1

    case Map.fetch(state.summaries, target) do
      {:ok, summary} ->
        {:reply, {:ok, summary}, %{state | awaited_turns: target}}

      :error ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        waiter = %{from: from, target: target, deadline: deadline}
        {:noreply, %{state | waiters: [waiter | state.waiters]}}
    end
  end

  @impl true
  def handle_call(:completed_turns, _from, state) do
    {:reply, state.completed_turns, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      state
      |> read_new_lines()
      |> serve_ready_waiters()
      |> expire_waiters()

    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Don't leave callers hung if we're shutting down.
    Enum.each(state.waiters, fn w -> GenServer.reply(w.from, {:error, :timeout}) end)
    :ok
  end

  # --- Tailing ---------------------------------------------------------------

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)

  defp read_new_lines(state) do
    case read_from_offset(state.path, state.offset) do
      {:ok, ""} ->
        state

      {:ok, data} ->
        combined = state.buffer <> data
        {complete_lines, leftover} = split_lines(combined)

        complete_lines
        |> Enum.reject(&(&1 == ""))
        |> Enum.reduce(%{state | offset: state.offset + byte_size(data), buffer: leftover}, &handle_line/2)

      {:error, reason} ->
        Logger.debug("SessionWatcher read failed path=#{state.path} reason=#{inspect(reason)}")
        state
    end
  end

  # Read everything appended since `offset`. A not-yet-created file (Claude writes
  # it on the first turn) reads as empty.
  defp read_from_offset(path, offset) do
    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          {:ok, _} = :file.position(fd, offset)

          case IO.binread(fd, :eof) do
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            other -> {:error, other}
          end
        after
          File.close(fd)
        end

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Split on newlines, holding any trailing partial line (a write in progress) for
  # the next poll.
  defp split_lines(combined) do
    case String.split(combined, "\n") do
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp handle_line(line, state) do
    case StreamParser.parse_line(line) do
      {:ok, event} ->
        state.on_event.(event)
        maybe_record_turn(event, state)

      {:error, reason} ->
        Logger.debug("SessionWatcher unparseable line reason=#{inspect(reason)}")
        state
    end
  end

  defp maybe_record_turn(event, state) do
    if turn_boundary?(event) do
      turn = state.completed_turns + 1

      summary = %{
        turn: turn,
        stop_reason: stop_reason(event),
        usage: StreamParser.extract_usage(event)
      }

      %{state | completed_turns: turn, summaries: Map.put(state.summaries, turn, summary)}
    else
      state
    end
  end

  # --- Turn-boundary detection ----------------------------------------------

  defp turn_boundary?(event) do
    Map.get(event, :event_type) == :assistant and not sidechain?(event) and
      stop_reason(event) in ["end_turn", "stop_sequence"]
  end

  defp sidechain?(event), do: Map.get(event, "isSidechain") == true || Map.get(event, :isSidechain) == true

  defp stop_reason(event) do
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    Map.get(message, "stop_reason") || Map.get(message, :stop_reason)
  end

  # --- Waiter handling -------------------------------------------------------

  # Reply to any waiter whose target turn has completed, in turn order, advancing
  # awaited_turns as we go.
  defp serve_ready_waiters(state) do
    {ready, pending} = Enum.split_with(state.waiters, fn w -> Map.has_key?(state.summaries, w.target) end)

    ready
    |> Enum.sort_by(& &1.target)
    |> Enum.reduce(%{state | waiters: pending}, fn w, acc ->
      GenServer.reply(w.from, {:ok, state.summaries[w.target]})
      %{acc | awaited_turns: max(acc.awaited_turns, w.target)}
    end)
  end

  defp expire_waiters(state) do
    now = System.monotonic_time(:millisecond)
    {expired, live} = Enum.split_with(state.waiters, fn w -> now >= w.deadline end)

    Enum.each(expired, fn w -> GenServer.reply(w.from, {:error, :timeout}) end)
    %{state | waiters: live}
  end
end
