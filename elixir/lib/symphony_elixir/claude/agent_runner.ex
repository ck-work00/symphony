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
      _comments_after = DateTime.utc_now()
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
         comments_after
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

        Logger.info(
          "Completed Claude agent turn for #{issue_context(issue)} session_id=#{effective_session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns} task_complete=#{task_complete}"
        )

        if task_complete do
          Logger.info(
            "Agent signaled SYMPHONY_TASK_COMPLETE for #{issue_context(issue)}, stopping"
          )

          :ok
        else
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
                turn_started_at
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

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, comments) do
    comments_section = format_comments_section(comments)

    """
    Continuation guidance (turn #{turn_number}/#{max_turns}):

    The previous turn completed normally, but the Linear issue is still in an active state.
    Resume from the current workspace state — do not restart from scratch.
    #{comments_section}
    FIRST, check if a PR already exists for this branch:
      gh pr list --head "$(git branch --show-current)" --json number,url,state --jq '.[0]'

    If a PR exists:
    1. Check CI status: `gh pr checks <number>`
    2. If CI is green (or still running) and no unaddressed review comments — you are DONE.
    3. If CI failed, fix the issue, push, then you are DONE.
    4. If there are review comments, address them, push, then you are DONE.

    If no PR exists, continue working toward shipping one.

    CRITICAL: When you are done, output this marker on its own line and STOP:
    SYMPHONY_TASK_COMPLETE

    Do NOT re-run tests or post additional test reports if the PR is already open and CI is passing.
    Do NOT look for more work. Do NOT expand scope.
    """
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

  defp format_comments_section([]), do: ""

  defp format_comments_section(comments) do
    formatted =
      comments
      |> Enum.map(fn c ->
        time = if c.created_at, do: Calendar.strftime(c.created_at, "%H:%M UTC"), else: "?"
        "  [#{time}] #{c.author}: #{c.body}"
      end)
      |> Enum.join("\n")

    """

    ## New comments on the Linear issue (from your team — read carefully and follow any instructions):
    #{formatted}

    """
  end

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
end
