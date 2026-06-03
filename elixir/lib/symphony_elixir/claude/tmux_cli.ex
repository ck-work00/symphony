defmodule SymphonyElixir.Claude.TmuxCLI do
  @moduledoc """
  Hosts a long-running, interactive Claude Code session inside a dedicated tmux
  session and delivers prompts to it.

  This replaces the `claude -p` (print mode) execution in
  `SymphonyElixir.Claude.CLI`. Print mode bills against Anthropic's programmatic
  credit pool; a long-running interactive `claude` bills against the plan.

  The session is created once per issue run. Prompts are delivered via
  `tmux load-buffer` + `paste-buffer` (atomic and reliable for any prompt size,
  unlike character-by-character `send-keys`). The structured event stream is NOT
  read from stdout here — interactive Claude Code writes the full event stream to
  a JSONL file, which `SymphonyElixir.Claude.SessionWatcher` tails. This module
  only owns the tmux/process lifecycle and prompt delivery.

  ## Session id

  The caller assigns a UUID and passes it to `claude --session-id`. That id is
  both the tmux session suffix and the JSONL filename, so we never have to derive
  Claude Code's escaped project-directory path (the escaping rule is more than
  `/`→`-`: underscores also become dashes). `session_jsonl_path/1` finds the file
  by its globally unique name instead.
  """

  require Logger
  alias SymphonyElixir.Config

  # Restrict to core tools only. MCP plugins (Playwright, Linear, Tidewave) add
  # 50-80 tools that consume hundreds of thousands of context tokens. Agents use
  # curl/bash for the Linear API and npx for Playwright instead.
  @agent_tools "Agent,Bash,Edit,Read,Write,Glob,Grep"
  @mcp_config_json "{\"mcpServers\":{}}"

  # The TUI can show its input prompt (`❯`) before it reliably accepts a pasted
  # buffer (e.g. while the welcome splash is still rendering at startup). A paste
  # sent in that window is silently dropped, so we verify the text landed in the
  # input and re-paste a few times before giving up.
  @paste_attempts 5

  @type session_handle :: %{
          session_id: String.t(),
          session_name: String.t(),
          workspace: Path.t()
        }

  @doc """
  Start a tmux-hosted interactive Claude Code session in `workspace`, using the
  caller-provided `session_id` (a valid UUID).

  Blocks until the TUI is ready (the `❯` prompt appears) or `ready_timeout_ms`
  elapses. Returns a session handle for the other functions in this module.
  """
  @spec start_session(Path.t(), String.t(), keyword()) ::
          {:ok, session_handle()} | {:error, term()}
  def start_session(workspace, session_id, opts \\ []) do
    with :ok <- validate_workspace(workspace),
         :ok <- ensure_tmux() do
      expanded = Path.expand(workspace)
      session_name = session_name(session_id)

      with :ok <- new_tmux_session(session_name, expanded),
           :ok <- launch_claude(session_name, session_id),
           :ok <- wait_for_ready(session_name, opts) do
        Logger.info("Started tmux Claude session session_id=#{session_id} session_name=#{session_name} workspace=#{expanded}")

        {:ok, %{session_id: session_id, session_name: session_name, workspace: expanded}}
      else
        {:error, reason} ->
          # Tear down a half-started session so we don't leak it.
          kill_session(session_name)
          {:error, reason}
      end
    end
  end

  @doc """
  Deliver `prompt` to the running session and submit it.

  Uses `load-buffer` + `paste-buffer` so arbitrarily large / multi-line prompts
  arrive intact, then sends Enter as a separate keystroke (tmux requires this).

  A short settle delay between paste and Enter is essential: the TUI processes the
  bracketed paste on its next render frame, and an Enter sent in the same frame is
  dropped (submitting nothing). `tmux_paste_settle_ms` controls the gap.
  """
  @spec send_prompt(session_handle(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def send_prompt(%{session_name: session_name, session_id: session_id}, prompt, turn)
      when is_binary(prompt) and is_integer(turn) do
    if alive?(session_name) do
      prompt_file = prompt_file_path(session_id, turn)

      with :ok <- File.write(prompt_file, prompt),
           :ok <- paste_until_visible(session_name, prompt_file, prompt, @paste_attempts),
           {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "Enter"]) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        {output, code} -> {:error, {:tmux_send_failed, code, String.trim(output)}}
      end
    else
      {:error, :session_not_alive}
    end
  end

  @doc """
  Stop the session: send `/exit` to let Claude close cleanly, then kill the tmux
  session (idempotent) and remove this session's prompt temp files.
  """
  @spec stop_session(session_handle()) :: :ok
  def stop_session(%{session_name: session_name, session_id: session_id}) do
    if alive?(session_name) do
      tmux(["send-keys", "-t", pane(session_name), "/exit"])
      tmux(["send-keys", "-t", pane(session_name), "Enter"])
      Process.sleep(2_000)
    end

    kill_session(session_name)
    cleanup_prompt_files(session_id)
    :ok
  end

  @doc "True if the tmux session still exists."
  @spec alive?(session_handle() | String.t()) :: boolean()
  def alive?(%{session_name: session_name}), do: alive?(session_name)

  def alive?(session_name) when is_binary(session_name) do
    match?({_, 0}, tmux(["has-session", "-t", session_name]))
  end

  @doc """
  Locate the session's JSONL event file by its globally unique `<session_id>.jsonl`
  filename under the Claude projects base path.

  Deliberately does NOT compute Claude Code's escaped project directory — that
  escaping rule is version-dependent and broader than `/`→`-`. Returns
  `{:error, :not_found}` until Claude writes the file (it appears on the first
  turn); callers poll.
  """
  @spec session_jsonl_path(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def session_jsonl_path(session_id) when is_binary(session_id) do
    base = Path.expand(Config.claude_tmux_jsonl_base_path())

    case Path.wildcard(Path.join([base, "*", "#{session_id}.jsonl"])) do
      [path | _] -> {:ok, path}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Poll `session_jsonl_path/1` until the JSONL file appears or the timeout elapses.
  """
  @spec await_jsonl(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :not_found}
  def await_jsonl(session_id, opts \\ []) do
    poll_ms = Keyword.get(opts, :poll_interval_ms, Config.claude_tmux_ready_poll_interval_ms())
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.claude_tmux_ready_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_jsonl(session_id, poll_ms, deadline)
  end

  @doc """
  Kill leftover Symphony tmux sessions and remove their prompt temp files.

  Called at application startup: a freshly-booted BEAM owns no agent runs, so any
  tmux session matching the Symphony prefix is a leak from a previous run that
  crashed before `stop_session/1` ran (the tmux session outlives the BEAM). This
  assumes a single Symphony orchestrator per host, which is the deployment model.

  Returns the list of session names reaped. Safe to call when no tmux server is
  running (returns `[]`).
  """
  @spec reap_orphan_sessions(String.t()) :: [String.t()]
  def reap_orphan_sessions(prefix \\ nil) do
    prefix = prefix || Config.claude_tmux_session_prefix()

    case tmux(["list-sessions", "-F", "#S"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, prefix <> "-"))
        |> Enum.map(fn name ->
          kill_session(name)
          cleanup_prompt_files(session_id_from_name(name, prefix))
          name
        end)

      _ ->
        # No tmux server (nothing to reap) or tmux not installed.
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp session_id_from_name(name, prefix), do: String.replace_prefix(name, prefix <> "-", "")

  defp settle_paste do
    Process.sleep(Config.claude_tmux_paste_settle_ms())
    :ok
  end

  # Clear the input, load the prompt buffer and paste it, then confirm the prompt
  # is visible in the pane. Clearing first makes a retry idempotent: a paste that
  # rendered slower than the settle delay won't be duplicated on the next attempt.
  # A single Ctrl-U only clears one visual line, so we repeat it to wipe a
  # multi-line input (e.g. an accumulated "[Pasted text]" block) entirely.
  defp paste_until_visible(_session_name, _prompt_file, _prompt, 0), do: {:error, :paste_not_visible}

  defp paste_until_visible(session_name, prompt_file, prompt, attempts_left) do
    with {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "-N", "25", "C-u"]),
         {_, 0} <- tmux(["load-buffer", prompt_file]),
         {_, 0} <- tmux(["paste-buffer", "-t", pane(session_name)]),
         :ok <- settle_paste() do
      if paste_visible?(session_name, prompt) do
        :ok
      else
        paste_until_visible(session_name, prompt_file, prompt, attempts_left - 1)
      end
    else
      {output, code} -> {:error, {:tmux_paste_failed, code, String.trim(output)}}
    end
  end

  # Confirm the paste reached the input box. We only inspect the bottom of the
  # pane (where the input box lives), so a previous turn's prompt still in the
  # transcript can't produce a false positive. Whitespace runs are squished
  # because the TUI may reflow the pasted text.
  #
  # Three independent signals, any of which proves the paste landed:
  #   * the prompt's SUFFIX — for a large multi-line prompt the TUI collapses the
  #     START into "[Pasted text #N]" placeholders but keeps the END literally at
  #     the cursor, so the suffix is the most reliable signal (the placeholders
  #     can scroll above our window when the literal tail is long);
  #   * the prompt's PREFIX — short prompts render entirely literally;
  #   * a "[Pasted text" placeholder — present when it happens to be in-window.
  @input_tail_lines 12

  defp paste_visible?(session_name, prompt) do
    {prefix, suffix} = prompt_needles(prompt)

    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} ->
        tail = input_tail(output)

        String.contains?(tail, "[Pasted text") or
          (suffix != "" and String.contains?(tail, suffix)) or
          (prefix != "" and String.contains?(tail, prefix))

      _ ->
        false
    end
  end

  # `capture-pane -p` right-pads the pane with blank lines, so we drop trailing
  # blanks before taking the tail — otherwise the window is all padding and the
  # input box (which sits above the footer) is missed.
  defp input_tail(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.take(@input_tail_lines)
    |> Enum.reverse()
    |> Enum.join(" ")
    |> squish()
  end

  # A distinctive prefix and suffix of the prompt (squished), each ~24 chars.
  defp prompt_needles(prompt) do
    squished = squish(prompt)
    prefix = String.slice(squished, 0, 24)
    suffix = if String.length(squished) > 24, do: String.slice(squished, -24, 24), else: ""
    {prefix, suffix}
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp session_name(session_id), do: "#{Config.claude_tmux_session_prefix()}-#{session_id}"

  # Claude Code runs in window 0 of the session; target it explicitly.
  defp pane(session_name), do: "#{session_name}:0"

  defp new_tmux_session(session_name, workspace) do
    args = [
      "new-session",
      "-d",
      "-s",
      session_name,
      "-x",
      Integer.to_string(Config.claude_tmux_width()),
      "-y",
      Integer.to_string(Config.claude_tmux_height()),
      "-c",
      workspace
    ]

    case tmux(args) do
      {_, 0} ->
        # Let tmux settle before sending keystrokes.
        Process.sleep(Config.claude_tmux_startup_delay_ms())
        :ok

      {output, code} ->
        {:error, {:tmux_new_session_failed, code, String.trim(output)}}
    end
  end

  defp launch_claude(session_name, session_id) do
    # `unset CLAUDECODE` so the nested CLI doesn't think it's running inside
    # another Claude Code session. Note: `--dangerously-skip-permissions` does
    # NOT suppress the per-directory "Do you trust this folder?" dialog on a
    # fresh workspace clone — `wait_for_ready` auto-answers it.
    command =
      "unset CLAUDECODE && #{claude_invocation(session_id)}"

    with {_, 0} <- tmux(["send-keys", "-t", pane(session_name), command]),
         {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "Enter"]) do
      :ok
    else
      {output, code} -> {:error, {:tmux_launch_failed, code, String.trim(output)}}
    end
  end

  defp claude_invocation(session_id) do
    base = [
      Config.claude_command(),
      "--session-id",
      session_id,
      "--tools",
      @agent_tools,
      "--mcp-config",
      single_quote(@mcp_config_json),
      "--strict-mcp-config"
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
    |> maybe_add_option(Config.claude_model(), "--model")
    |> Enum.join(" ")
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _false, _flag), do: args

  defp maybe_add_option(args, nil, _opt), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  # The mcp-config JSON contains characters the shell would mangle; quote it.
  defp single_quote(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"

  defp wait_for_ready(session_name, opts) do
    poll_ms = Keyword.get(opts, :ready_poll_interval_ms, Config.claude_tmux_ready_poll_interval_ms())
    timeout_ms = Keyword.get(opts, :ready_timeout_ms, Config.claude_tmux_ready_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(session_name, poll_ms, deadline)
  end

  defp do_wait_for_ready(session_name, poll_ms, deadline) do
    cond do
      not alive?(session_name) ->
        {:error, :session_died_during_startup}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :ready_timeout}

      true ->
        case pane_state(session_name) do
          :ready ->
            :ok

          :trust ->
            # Accept the "Do you trust this folder?" dialog ("1. Yes" is the
            # default selection). The workspace is always our own fresh clone.
            tmux(["send-keys", "-t", pane(session_name), "Enter"])
            Process.sleep(poll_ms)
            do_wait_for_ready(session_name, poll_ms, deadline)

          :pending ->
            Process.sleep(poll_ms)
            do_wait_for_ready(session_name, poll_ms, deadline)
        end
    end
  end

  # Classify the current screen from a pane capture:
  #   :trust   — the per-directory trust dialog is up (auto-answer it)
  #   :ready   — the main input is live (the footer token counter is present,
  #              which no modal dialog shows)
  #   :pending — still starting up / some other transient screen
  # An unknown modal stays :pending and we time out loudly rather than paste into
  # the wrong context.
  defp pane_state(session_name) do
    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} ->
        cond do
          trust_dialog?(output) -> :trust
          input_ready?(output) -> :ready
          true -> :pending
        end

      _ ->
        :pending
    end
  end

  defp trust_dialog?(output) do
    String.contains?(output, "trust this folder") or
      String.contains?(output, "trust the files")
  end

  # The main TUI footer always shows a "<n> tokens" counter; modal dialogs (trust,
  # onboarding) do not. Pairing that with the "❯" input marker is a reliable
  # "ready for a prompt" signal.
  defp input_ready?(output) do
    String.contains?(output, "❯") and Regex.match?(~r/\d+\s+tokens/, output)
  end

  defp do_await_jsonl(session_id, poll_ms, deadline) do
    case session_jsonl_path(session_id) do
      {:ok, path} ->
        {:ok, path}

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :not_found}
        else
          Process.sleep(poll_ms)
          do_await_jsonl(session_id, poll_ms, deadline)
        end
    end
  end

  defp kill_session(session_name) do
    tmux(["kill-session", "-t", session_name])
    :ok
  end

  defp prompt_file_path(session_id, turn) do
    Path.join(System.tmp_dir!(), "symphony-#{session_id}-#{turn}.txt")
  end

  defp cleanup_prompt_files(session_id) do
    Path.join(System.tmp_dir!(), "symphony-#{session_id}-*.txt")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp ensure_tmux do
    if System.find_executable("tmux"), do: :ok, else: {:error, :tmux_not_found}
  end

  defp tmux(args) do
    System.cmd("tmux", args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {Exception.message(e), 1}
  end

  # Same workspace guardrails as SymphonyElixir.Claude.CLI: only run inside the
  # configured workspace root or the pool-slot root.
  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    pool_root = Path.expand("~/Documents/Gearflow")

    cond do
      !File.dir?(expanded) -> {:error, {:invalid_workspace_cwd, :not_a_directory}}
      String.starts_with?(expanded, root) -> :ok
      String.starts_with?(expanded, pool_root) -> :ok
      true -> {:error, {:invalid_workspace_cwd, :outside_root}}
    end
  end
end
