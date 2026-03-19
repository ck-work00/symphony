defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{Config, Evaluator, History, StatusDashboard, Suitability, Tracker, Workspace}
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 30_000
  @max_continuations 5
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      running: %{},
      completed: MapSet.new(),
      completed_history: [],
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    now_ms = System.monotonic_time(:millisecond)
    next_poll_due_at_ms = now_ms + state.poll_interval_ms
    :ok = schedule_tick(state.poll_interval_ms)

    state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_poll_due_at_ms}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        state = record_completed_history(state, running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              continuation_count = Map.get(running_entry, :continuation_count, 0) + 1
              has_pr = Map.get(running_entry, :pr_url) != nil
              # Allow one continuation after PR to check review comments, then stop
              pr_continuation_exhausted = has_pr and continuation_count > 1

              cond do
                pr_continuation_exhausted ->
                  Logger.info(
                    "Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; PR exists (#{running_entry.pr_url}) and review pass done, not re-dispatching"
                  )

                  complete_issue(state, issue_id)

                continuation_count > @max_continuations ->
                  Logger.warning(
                    "Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; reached max continuations (#{@max_continuations}), not re-dispatching"
                  )

                  complete_issue(state, issue_id)

                true ->
                  reason_str = if has_pr, do: "PR review pass", else: "continuation"

                  Logger.info(
                    "Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling #{reason_str} #{continuation_count}/#{@max_continuations}"
                  )

                  state
                  |> complete_issue(issue_id)
                  |> schedule_issue_retry(issue_id, continuation_count, %{
                    identifier: running_entry.identifier,
                    delay_type: :continuation,
                    continuation_count: continuation_count
                  })
              end

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}"
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        # Record phase transition events
        record_phase_transition_events(running_entry, updated_running_entry, issue_id)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    if not Config.within_active_hours?() do
      Logger.debug("Outside active hours, skipping dispatch")
      state
    else
      do_dispatch(state)
    end
  end

  defp do_dispatch(%State{} = state) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_linear_filter} ->
        Logger.error("No Linear targeting configured in WORKFLOW.md (need project_slug or filter)")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, :missing_codex_command} ->
        Logger.error("Codex command missing in WORKFLOW.md")
        state

      {:error, {:invalid_codex_approval_policy, value}} ->
        Logger.error("Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_codex_thread_sandbox, value}} ->
        Logger.error("Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_codex_turn_sandbox_policy, reason}} ->
        Logger.error("Invalid codex.turn_sandbox_policy in WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          reconcile_running_issue_states(
            issues,
            state,
            active_state_set(),
            terminal_state_set()
          )

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.codex_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)
    phase_elapsed_ms = phase_stall_elapsed_ms(running_entry, now)
    phase_timeout_ms = timeout_ms * 2

    stall_reason =
      cond do
        is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
          "stalled for #{elapsed_ms}ms without codex activity"

        is_integer(phase_elapsed_ms) and phase_elapsed_ms > phase_timeout_ms ->
          "phase stuck for #{phase_elapsed_ms}ms (phase=#{Map.get(running_entry, :phase)})"

        true ->
          nil
      end

    if stall_reason do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}; #{stall_reason}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: stall_reason
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    result = candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      suitable_issue?(issue) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)

    result
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp suitable_issue?(%Issue{} = issue) do
    case Suitability.screen(issue) do
      :ok ->
        true

      {:skip, reason} ->
        Logger.info("Skipping unsuitable issue #{issue.identifier}: #{reason}")
        false
    end
  end

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, metadata \\ %{}) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        case check_existing_pr(refreshed_issue) do
          {:pr_exists, pr_url} ->
            Logger.info("Skipping dispatch; open PR already exists for #{issue_context(refreshed_issue)}: #{pr_url}")
            complete_issue(state, refreshed_issue.id)

          :no_pr ->
            do_dispatch_issue(state, refreshed_issue, attempt, metadata)
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  rescue
    error ->
      Logger.error("dispatch_issue crashed for #{issue_context(issue)}: #{Exception.message(error)}")
      state
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, metadata) do
    recipient = self()

    runner = Config.agent_runner_module()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           runner.run(issue, recipient, attempt: attempt)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        # Remove any stale completed_history entry if this issue is being re-dispatched
        completed_history =
          Enum.reject(state.completed_history, fn entry ->
            entry[:issue_identifier] == issue.identifier
          end)

        now = DateTime.utc_now()
        history_run_id = record_dispatch_to_history(issue, attempt, now)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            phase: nil,
            pr_url: nil,
            retry_attempt: normalize_retry_attempt(attempt),
            continuation_count: Map.get(metadata, :continuation_count, 0),
            started_at: now,
            phase_changed_at: now,
            phases_seen: [],
            screenshot_urls: [],
            history_run_id: history_run_id
          })

        %{
          state
          | running: running,
            completed_history: completed_history,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1

    # Enforce max failure retries (does not apply to continuations)
    if metadata[:delay_type] != :continuation and next_attempt > Config.max_failure_retries() do
      exhaust_failure_retries(state, issue_id, previous_retry, next_attempt, metadata)
    else
      do_schedule_issue_retry(state, issue_id, next_attempt, previous_retry, metadata)
    end
  end

  defp exhaust_failure_retries(state, issue_id, previous_retry, next_attempt, metadata) do
    identifier = metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id

    Logger.warning(
      "Max failure retries (#{Config.max_failure_retries()}) exhausted for issue_id=#{issue_id} issue_identifier=#{identifier}; stopping"
    )

    state = complete_issue(state, issue_id)
    record_max_retries_event(state, issue_id, identifier, next_attempt)
    state
  end

  defp do_schedule_issue_retry(%State{} = state, issue_id, next_attempt, previous_retry, metadata) do
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            continuation_count: Map.get(metadata, :continuation_count, 0)
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          continuation_count: Map.get(retry_entry, :continuation_count, 0)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation do
      # Exponential backoff: 30s, 60s, 120s, 240s, ...
      min(@continuation_retry_delay_ms * (1 <<< (attempt - 1)), Config.max_retry_backoff_ms())
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          phase: Map.get(metadata, :phase),
          phases_seen: Map.get(metadata, :phases_seen, []),
          phase_changed_at: Map.get(metadata, :phase_changed_at),
          pr_url: Map.get(metadata, :pr_url),
          screenshot_urls: Map.get(metadata, :screenshot_urls, []),
          history_run_id: Map.get(metadata, :history_run_id),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       completed_history: state.completed_history,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:stop_issue, issue_id}, _from, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      running_entry ->
        Logger.warning("Stopping issue via dashboard action: issue_id=#{issue_id} issue_identifier=#{running_entry.identifier}")

        state =
          state
          |> terminate_running_issue(issue_id, false)
          |> record_completed_history(running_entry, {:shutdown, :stopped})
          |> record_session_completion_totals(running_entry)
          |> complete_issue(issue_id)

        notify_dashboard()
        {:reply, :ok, state}
    end
  end

  def handle_call({:retry_issue_manual, issue_id}, _from, state) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        Logger.info("Manual retry via dashboard action: #{issue_context(issue)}")
        state = dispatch_issue(state, issue)
        notify_dashboard()
        {:reply, :ok, state}

      {:ok, []} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_retry, issue_id}, _from, state) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{timer_ref: timer_ref} ->
        if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

        Logger.info("Cancelled retry via dashboard action: issue_id=#{issue_id}")

        state = %{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id)
        }

        notify_dashboard()
        {:reply, :ok, state}
    end
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    # Detect phase and PR URL from agent messages (sticky — only updates when found)
    old_phase = Map.get(running_entry, :phase)
    phase = phase_for_update(running_entry, update)
    pr_url = pr_url_for_update(running_entry, update)
    _old_pr_url = Map.get(running_entry, :pr_url)

    # Track screenshot URLs from Playwright tool uses
    screenshot_urls = screenshot_urls_for_update(running_entry, update)

    # Update phase_changed_at and phases_seen when phase transitions
    existing_phases = Map.get(running_entry, :phases_seen, [])

    {phase_changed_at, phases_seen} =
      if phase != old_phase and phase != nil do
        updated_phases =
          if phase in existing_phases, do: existing_phases, else: existing_phases ++ [phase]

        {timestamp, updated_phases}
      else
        {Map.get(running_entry, :phase_changed_at, timestamp), existing_phases}
      end

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        phase: phase,
        phase_changed_at: phase_changed_at,
        phases_seen: phases_seen,
        pr_url: pr_url,
        screenshot_urls: screenshot_urls,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp phase_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    case StreamParser.extract_phase(raw) do
      nil -> Map.get(running_entry, :phase)
      phase -> phase
    end
  end

  defp phase_for_update(running_entry, _update), do: Map.get(running_entry, :phase)

  defp pr_url_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    case StreamParser.extract_pr_url(raw) do
      nil -> Map.get(running_entry, :pr_url)
      url -> url
    end
  end

  defp pr_url_for_update(running_entry, _update), do: Map.get(running_entry, :pr_url)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp record_completed_history(%State{} = state, running_entry, reason)
       when is_map(running_entry) do
    now = DateTime.utc_now()
    outcome = if(reason == :normal, do: "completed", else: "failed")

    summary = %{
      issue_id: running_entry[:identifier] || "unknown",
      issue_identifier: running_entry[:identifier],
      started_at: running_entry[:started_at],
      completed_at: now,
      phase: Map.get(running_entry, :phase),
      phases_seen: Map.get(running_entry, :phases_seen, []),
      pr_url: Map.get(running_entry, :pr_url),
      outcome: outcome,
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: %{
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0)
      }
    }

    record_completion_to_history(running_entry, outcome, reason, now)

    %{state | completed_history: [summary | state.completed_history]}
  end

  defp record_completed_history(state, _running_entry, _reason), do: state

  defp record_dispatch_to_history(issue, attempt, now) do
    attrs = %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      issue_priority: issue.priority,
      issue_labels: issue.labels || [],
      filter_source: "project",
      project_slug: Config.linear_project_slug(),
      started_at: now,
      agent_backend: Config.agent_backend(),
      retry_attempt: normalize_retry_attempt(attempt) || 0
    }

    case History.record_dispatch(attrs) do
      {:ok, run} ->
        run.id

      {:error, reason} ->
        Logger.warning("Failed to record dispatch to history: #{inspect(reason)}")
        nil
    end
  end

  defp record_completion_to_history(running_entry, outcome, reason, now) do
    run_id = Map.get(running_entry, :history_run_id)

    if run_id do
      started_at = Map.get(running_entry, :started_at)

      wall_clock_ms =
        if started_at do
          DateTime.diff(now, started_at, :millisecond)
        end

      error_info = categorize_error(reason)

      attrs = %{
        finished_at: now,
        outcome: outcome,
        session_id: Map.get(running_entry, :session_id),
        turns_used: Map.get(running_entry, :turn_count, 0),
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
        wall_clock_ms: wall_clock_ms,
        final_phase: Map.get(running_entry, :phase),
        error_message: error_info[:message],
        error_category: error_info[:category]
      }

      # Record completion, then run evaluation
      case History.record_completion(run_id, attrs) do
        {:ok, _run} ->
          run_context = %{
            issue_id: Map.get(running_entry, :issue, %{}) |> Map.get(:id),
            branch_name: Map.get(running_entry, :issue, %{}) |> Map.get(:branch_name),
            identifier: Map.get(running_entry, :identifier)
          }

          identifier = running_entry[:identifier]
          safe_id = if identifier, do: String.replace(identifier, ~r/[^a-zA-Z0-9_\-]/, ""), else: nil
          workspace_path = if safe_id, do: Path.join(Config.workspace_root(), safe_id), else: nil
          Evaluator.evaluate_and_record(run_id, run_context, workspace_path)

        {:error, reason} ->
          Logger.warning("Failed to record completion to history: #{inspect(reason)}")
      end
    end
  rescue
    error ->
      Logger.warning("Failed to record completion to history: #{Exception.message(error)}")
  end

  defp categorize_error(:normal), do: %{message: nil, category: nil}

  defp categorize_error({:shutdown, :stopped}),
    do: %{message: "stopped via dashboard", category: "stopped"}

  defp categorize_error(reason) do
    message = inspect(reason)

    category =
      cond do
        message =~ "max_retries_exhausted" -> "max_retries_exhausted"
        message =~ "timeout" or message =~ "Timeout" -> "timeout"
        message =~ "stall" or message =~ "Stall" -> "stall"
        message =~ "rate_limit" or message =~ "429" -> "rate_limit"
        message =~ "spawn" -> "spawn_failure"
        true -> "crash"
      end

    %{message: String.slice(message, 0, 500), category: category}
  end

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &flat_token_usage/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  # Recognizes a flat usage map like %{input_tokens: N, output_tokens: N, total_tokens: N}
  # produced by Claude Code's StreamParser.extract_usage/1.
  defp flat_token_usage(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp flat_token_usage(_), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  # ---------------------------------------------------------------------------
  # Phase-aware stall detection
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Pre-dispatch PR check
  # ---------------------------------------------------------------------------

  defp check_existing_pr(%Issue{identifier: identifier, labels: labels}) when is_binary(identifier) do
    repos = repos_for_labels(labels)
    branches = [identifier, String.downcase(identifier)]

    result =
      Enum.find_value(repos, fn repo ->
        Enum.find_value(branches, fn branch ->
          case System.cmd("gh", ["pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--json", "url", "--jq", ".[0].url"],
                 stderr_to_stdout: true
               ) do
            {url, 0} ->
              trimmed = String.trim(url)
              if trimmed != "" and String.starts_with?(trimmed, "http"), do: trimmed

            _ ->
              nil
          end
        end)
      end)

    case result do
      nil -> :no_pr
      url -> {:pr_exists, url}
    end
  rescue
    _ -> :no_pr
  end

  defp check_existing_pr(_issue), do: :no_pr

  defp repos_for_labels(labels) when is_list(labels) do
    has_platform = Enum.any?(labels, fn l -> String.downcase(l) |> String.starts_with?("2.0") end)
    has_procurement = Enum.any?(labels, fn l -> String.downcase(l) |> String.starts_with?("3.0") end)

    cond do
      has_platform and has_procurement -> ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]
      has_platform -> ["GearFlowDev/gf_platform"]
      has_procurement -> ["GearFlowDev/gf_procurement"]
      true -> ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]
    end
  end

  defp repos_for_labels(_), do: ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]

  defp phase_stall_elapsed_ms(running_entry, now) do
    case Map.get(running_entry, :phase_changed_at) do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Screenshot URL tracking
  # ---------------------------------------------------------------------------

  defp screenshot_urls_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    existing = Map.get(running_entry, :screenshot_urls, [])
    new_urls = StreamParser.extract_screenshot_urls(raw)

    case new_urls do
      [] -> existing
      urls -> Enum.uniq(existing ++ urls)
    end
  end

  defp screenshot_urls_for_update(running_entry, _update),
    do: Map.get(running_entry, :screenshot_urls, [])

  # ---------------------------------------------------------------------------
  # Phase transition event recording
  # ---------------------------------------------------------------------------

  defp record_phase_transition_events(old_entry, new_entry, issue_id) do
    run_id = Map.get(new_entry, :history_run_id)
    unless run_id, do: throw(:skip)

    old_phase = Map.get(old_entry, :phase)
    new_phase = Map.get(new_entry, :phase)
    old_pr_url = Map.get(old_entry, :pr_url)
    new_pr_url = Map.get(new_entry, :pr_url)
    old_screenshots = Map.get(old_entry, :screenshot_urls, [])
    new_screenshots = Map.get(new_entry, :screenshot_urls, [])

    now = DateTime.utc_now()

    # Phase change event
    if new_phase != old_phase and new_phase != nil do
      History.record_event(%{
        run_id: run_id,
        event_type: "phase_change",
        payload: %{from: old_phase, to: new_phase},
        timestamp: now
      })

      # Milestone events (deduplicated via phase check)
      record_milestone_event(run_id, old_phase, new_phase, now)
    end

    # PR created milestone
    if new_pr_url != nil and old_pr_url == nil do
      History.record_event(%{
        run_id: run_id,
        event_type: "milestone_pr_created",
        payload: %{pr_url: new_pr_url},
        timestamp: now
      })
    end

    # Screenshot captured
    if length(new_screenshots) > length(old_screenshots) do
      new_urls = new_screenshots -- old_screenshots

      Enum.each(new_urls, fn url ->
        History.record_event(%{
          run_id: run_id,
          event_type: "screenshot_captured",
          payload: %{url: url, issue_id: issue_id},
          timestamp: now
        })
      end)
    end

    :ok
  catch
    :skip -> :ok
  end

  defp record_milestone_event(run_id, old_phase, new_phase, now) do
    normalized_new = new_phase && String.downcase(new_phase)
    normalized_old = old_phase && String.downcase(old_phase)

    cond do
      normalized_new && String.contains?(normalized_new, "implement") and
          (normalized_old == nil or not String.contains?(normalized_old, "implement")) ->
        History.record_event(%{
          run_id: run_id,
          event_type: "milestone_first_edit",
          payload: %{phase: new_phase},
          timestamp: now
        })

      normalized_new && String.contains?(normalized_new, "test") and
          (normalized_old == nil or not String.contains?(normalized_old, "test")) ->
        History.record_event(%{
          run_id: run_id,
          event_type: "milestone_tests_run",
          payload: %{phase: new_phase},
          timestamp: now
        })

      true ->
        :ok
    end
  end

  defp record_max_retries_event(_state, issue_id, identifier, attempt) do
    Logger.info(
      "Recording max_retries_exhausted for issue_id=#{issue_id} issue_identifier=#{identifier} attempt=#{attempt}"
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer actions: stop, retry, cancel
  # ---------------------------------------------------------------------------

  @spec stop_issue(String.t()) :: :ok | {:error, :not_running}
  def stop_issue(issue_id), do: stop_issue(__MODULE__, issue_id)

  @spec stop_issue(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def stop_issue(server, issue_id) do
    GenServer.call(server, {:stop_issue, issue_id})
  end

  @spec retry_issue_manual(String.t()) :: :ok | {:error, :not_found}
  def retry_issue_manual(issue_id), do: retry_issue_manual(__MODULE__, issue_id)

  @spec retry_issue_manual(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def retry_issue_manual(server, issue_id) do
    GenServer.call(server, {:retry_issue_manual, issue_id})
  end

  @spec cancel_retry(String.t()) :: :ok | {:error, :not_found}
  def cancel_retry(issue_id), do: cancel_retry(__MODULE__, issue_id)

  @spec cancel_retry(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def cancel_retry(server, issue_id) do
    GenServer.call(server, {:cancel_retry, issue_id})
  end
end
