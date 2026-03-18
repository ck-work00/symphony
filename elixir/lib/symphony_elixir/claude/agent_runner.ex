defmodule SymphonyElixir.Claude.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Claude Code.

  Drop-in replacement for `SymphonyElixir.AgentRunner` (which uses Codex).
  Same public interface: `run/3` with identical argument shapes and message
  protocol so the orchestrator can dispatch to either backend.
  """

  require Logger
  alias SymphonyElixir.Claude.CLI, as: ClaudeCLI
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.{Config, Linear.Client, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting Claude agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting),
               :ok <- run_claude_turns(workspace, issue, claude_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp claude_event_handler(recipient, issue) do
    fn event ->
      send_claude_update(recipient, issue, event)
    end
  end

  # Emit updates in the same {:codex_worker_update, ...} format the orchestrator
  # expects, so we stay compatible without rewriting the orchestrator.
  defp send_claude_update(recipient, %Issue{id: issue_id}, event)
       when is_binary(issue_id) and is_pid(recipient) do
    timestamp = DateTime.utc_now()
    session_id = StreamParser.extract_session_id(event)
    usage = StreamParser.extract_usage(event)
    event_type = Map.get(event, :event_type, :unknown)

    send(
      recipient,
      {:codex_worker_update, issue_id,
       %{
         event: event_type,
         timestamp: timestamp,
         session_id: session_id,
         usage: usage,
         raw: event
       }}
    )

    :ok
  end

  defp send_claude_update(_recipient, _issue, _event), do: :ok

  defp send_phase_update(recipient, %Issue{id: issue_id}, phase)
       when is_pid(recipient) and is_atom(phase) do
    send(
      recipient,
      {:codex_worker_update, issue_id,
       %{
         event: phase,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: %{}
       }}
    )

    :ok
  end

  defp send_phase_update(_recipient, _issue, _phase), do: :ok

  defp run_claude_turns(workspace, issue, claude_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    comment_fetcher =
      Keyword.get(opts, :comment_fetcher, &Client.fetch_issue_comments/2)

    do_run_claude_turns(
      workspace,
      issue,
      claude_update_recipient,
      opts,
      issue_state_fetcher,
      comment_fetcher,
      1,
      max_turns,
      _session_id = nil,
      _comments_after = DateTime.utc_now(),
      _no_progress_count = 0
    )
  end

  defp do_run_claude_turns(
         workspace,
         issue,
         claude_update_recipient,
         opts,
         issue_state_fetcher,
         comment_fetcher,
         turn_number,
         max_turns,
         session_id,
         comments_after,
         no_progress_count
       ) do
    comments = fetch_new_comments(issue, comment_fetcher, turn_number, comments_after)
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, comments)

    # Advance the watermark so the next turn only sees newer comments
    turn_started_at = DateTime.utc_now()

    cli_opts = [
      on_event: claude_event_handler(claude_update_recipient, issue)
    ]

    result =
      if session_id == nil do
        ClaudeCLI.run(prompt, workspace, cli_opts)
      else
        ClaudeCLI.resume(session_id, prompt, workspace, cli_opts)
      end

    case result do
      {:ok, %{session_id: new_session_id} = cli_result} ->
        effective_session_id = new_session_id || session_id
        task_complete = Map.get(cli_result, :task_complete, false)

        # Check workspace progress after each turn
        progress = check_turn_progress(workspace)
        made_progress = progress.files_changed > 0 or progress.new_commits > 0 or task_complete
        next_no_progress = if made_progress, do: 0, else: no_progress_count + 1

        Logger.info(
          "Completed Claude agent turn for #{issue_context(issue)} session_id=#{effective_session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns} task_complete=#{task_complete} progress=#{inspect(progress)} no_progress_count=#{next_no_progress}"
        )

        cond do
          task_complete ->
            Logger.info(
              "Agent signaled SYMPHONY_TASK_COMPLETE for #{issue_context(issue)}, stopping"
            )

            :ok

          next_no_progress >= 2 ->
            Logger.warning(
              "No progress for #{next_no_progress} consecutive turns for #{issue_context(issue)}, stopping early"
            )

            :ok

          true ->
            case continue_with_issue?(issue, issue_state_fetcher) do
              {:continue, refreshed_issue} when turn_number < max_turns ->
                Logger.info(
                  "Continuing Claude agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}"
                )

                do_run_claude_turns(
                  workspace,
                  refreshed_issue,
                  claude_update_recipient,
                  opts,
                  issue_state_fetcher,
                  comment_fetcher,
                  turn_number + 1,
                  max_turns,
                  effective_session_id,
                  turn_started_at,
                  next_no_progress
                )

              {:continue, refreshed_issue} ->
                Logger.info(
                  "Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active"
                )

                :ok

              {:done, _refreshed_issue} ->
                :ok

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _comments) do
    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(issue, _opts, turn_number, max_turns, comments) do
    PromptBuilder.build_continuation_prompt(issue, turn_number, max_turns, comments)
  end

  defp fetch_new_comments(_issue, _comment_fetcher, 1, _comments_after), do: []

  defp fetch_new_comments(%Issue{id: issue_id}, comment_fetcher, _turn, comments_after)
       when is_binary(issue_id) do
    case comment_fetcher.(issue_id, comments_after) do
      {:ok, comments} -> comments
      _ -> []
    end
  end

  defp fetch_new_comments(_issue, _comment_fetcher, _turn, _comments_after), do: []

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp check_turn_progress(workspace) do
    files_changed = count_git_changes(workspace)
    new_commits = count_new_commits(workspace)
    %{files_changed: files_changed, new_commits: new_commits}
  end

  defp count_git_changes(workspace) do
    case System.cmd("git", ["diff", "--stat", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> length()

      _ ->
        0
    end
  end

  defp count_new_commits(workspace) do
    case System.cmd("git", ["log", "--oneline", "@{upstream}..HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> length()

      _ ->
        0
    end
  end
end
