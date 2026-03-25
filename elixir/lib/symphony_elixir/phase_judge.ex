defmodule SymphonyElixir.PhaseJudge do
  @moduledoc """
  External judge that evaluates which workflow phases an agent completed.

  Uses local history (SQLite) as the primary source of truth. All runs and
  events for an issue are aggregated to determine what has been accomplished
  across restarts and retask continuations.

  After each agent run, the orchestrator calls `assess/2` to decide whether the
  run is done or needs a targeted retask on only the missing phases.
  """

  require Logger

  alias SymphonyElixir.History

  @phases_in_order ["Investigate", "Implement", "Test", "Ship", "Share Evidence"]

  # Maximum total runs per issue before we stop retrying.
  @max_runs_per_issue 8

  @type assessment :: :done | :max_runs_reached | {:retask, missing :: [String.t()], completed :: [String.t()]}

  @doc """
  Assess a completed running entry using local history.

  Queries all prior runs and events for this issue to build the full picture,
  then merges in signals from the current run.

  Returns `:done`, `:max_runs_reached`, or `{:retask, missing, completed}`.
  """
  @spec assess(map()) :: assessment()
  def assess(running_entry) do
    identifier = running_entry[:identifier]
    summary = History.issue_summary(identifier)

    # Hard stop: too many runs means something is wrong
    if summary.total_runs >= @max_runs_per_issue do
      Logger.warning("PhaseJudge: issue=#{identifier} reached #{summary.total_runs} runs (max #{@max_runs_per_issue}), stopping")
      :max_runs_reached
    else
      # Build completed phases from history + current run
      from_history = phases_from_history(summary)
      from_current = detect_completed_phases(running_entry)
      from_prior = Map.get(running_entry, :completed_phases, [])
      completed = Enum.uniq(from_history ++ from_current ++ from_prior)
      missing = @phases_in_order -- completed

      # Last resort: check Linear for evidence the stream parser missed
      {missing, completed} = maybe_check_linear_evidence(missing, completed, running_entry)

      Logger.info("PhaseJudge: issue=#{identifier} completed=#{inspect(completed)} missing=#{inspect(missing)} total_runs=#{summary.total_runs}")

      if missing == [] do
        :done
      else
        {:retask, missing, completed}
      end
    end
  end

  @doc """
  Pre-dispatch assessment using local history.

  Checks history and external signals (open PR, Linear evidence) to decide
  whether to dispatch, skip, or retask.
  """
  @spec pre_dispatch_assess(map(), String.t() | nil) :: :fresh | assessment()
  def pre_dispatch_assess(issue, pr_url) do
    identifier = issue_id(issue)
    summary = History.issue_summary(identifier)

    if summary.total_runs >= @max_runs_per_issue do
      Logger.warning("PhaseJudge pre-dispatch: issue=#{identifier} reached #{summary.total_runs} runs, not dispatching")
      :max_runs_reached
    else
      from_history = phases_from_history(summary)

      # Add phases implied by external signals
      from_external =
        []
        |> then(fn p -> if pr_url != nil, do: ["Investigate", "Implement", "Ship"] ++ p, else: p end)
        |> then(fn p -> if summary.has_evidence, do: ["Share Evidence"] ++ p, else: p end)
        |> then(fn p -> if summary.has_tests, do: ["Test"] ++ p, else: p end)

      completed = Enum.uniq(from_history ++ from_external)
      missing = @phases_in_order -- completed

      # Check Linear if still missing evidence
      {missing, completed} =
        if missing != [] and missing -- ["Test", "Share Evidence"] == [] do
          if check_linear_evidence(issue) do
            {[], @phases_in_order}
          else
            {missing, completed}
          end
        else
          {missing, completed}
        end

      Logger.info("PhaseJudge pre-dispatch: issue=#{identifier} pr=#{pr_url} completed=#{inspect(completed)} missing=#{inspect(missing)} total_runs=#{summary.total_runs}")

      cond do
        summary.total_runs == 0 and pr_url == nil -> :fresh
        missing == [] -> :done
        true -> {:retask, missing, completed}
      end
    end
  end

  @doc "Returns the canonical phase order."
  def phases_in_order, do: @phases_in_order

  @doc "Maximum runs per issue before forced stop."
  def max_runs_per_issue, do: @max_runs_per_issue

  # ---------------------------------------------------------------------------
  # History-based phase detection
  # ---------------------------------------------------------------------------

  defp phases_from_history(summary) do
    phases = []

    # Phases observed in event stream across all runs
    history_phases = summary.phases_seen

    phases = if Enum.any?(history_phases, &String.contains?(&1, "Investigate")), do: ["Investigate" | phases], else: phases
    phases = if Enum.any?(history_phases, &String.contains?(&1, "Implement")), do: ["Implement" | phases], else: phases
    phases = if Enum.any?(history_phases, &String.contains?(&1, "Test")), do: ["Test" | phases], else: phases
    phases = if Enum.any?(history_phases, &String.contains?(&1, "Ship")), do: ["Ship" | phases], else: phases
    phases = if Enum.any?(history_phases, &String.contains?(&1, "Share Evidence")), do: ["Share Evidence" | phases], else: phases

    # Milestones from events
    event_types = summary.events |> Enum.map(& &1.event_type) |> MapSet.new()

    phases = if MapSet.member?(event_types, "milestone_pr_created") or summary.has_pr, do: Enum.uniq(["Ship" | phases]), else: phases
    phases = if MapSet.member?(event_types, "milestone_first_edit"), do: Enum.uniq(["Implement" | phases]), else: phases
    phases = if MapSet.member?(event_types, "milestone_tests_run"), do: Enum.uniq(["Test" | phases]), else: phases
    phases = if length(summary.screenshots) > 0 or summary.has_evidence, do: Enum.uniq(["Share Evidence" | phases]), else: phases

    Enum.uniq(phases)
  end

  # ---------------------------------------------------------------------------
  # Evidence checks — probes Linear for screenshots/comments
  # ---------------------------------------------------------------------------

  defp maybe_check_linear_evidence(missing, completed, running_entry) do
    if missing != [] and missing -- ["Test", "Share Evidence"] == [] do
      issue = Map.get(running_entry, :issue)

      if issue != nil and check_linear_evidence(issue) do
        Logger.info("PhaseJudge: Linear evidence found for #{running_entry[:identifier]}, marking Test+Share Evidence done")
        {[], @phases_in_order}
      else
        {missing, completed}
      end
    else
      {missing, completed}
    end
  end

  @doc "Check whether the Linear issue has screenshot evidence in its comments."
  @spec check_linear_evidence(map()) :: boolean()
  def check_linear_evidence(%{id: issue_id}) when is_binary(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        all_text = comments |> Enum.map(& &1.body) |> Enum.join("\n")
        String.contains?(all_text, "![") or String.contains?(all_text, "screenshot")

      _ ->
        false
    end
  end

  def check_linear_evidence(_), do: false

  defp issue_id(%{identifier: id}) when is_binary(id), do: id
  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(_), do: "unknown"

  # ---------------------------------------------------------------------------
  # Current-run phase detection — signals from the running entry
  # ---------------------------------------------------------------------------

  defp detect_completed_phases(entry) do
    phases_seen = Map.get(entry, :phases_seen, [])

    phases = []
    phases = if "Investigate" in phases_seen or has_code_changes?(entry), do: ["Investigate" | phases], else: phases
    phases = if "Implement" in phases_seen or has_code_changes?(entry), do: ["Implement" | phases], else: phases
    phases = if "Test" in phases_seen and has_screenshots?(entry), do: ["Test" | phases], else: phases
    phases = if has_pr?(entry), do: ["Ship" | phases], else: phases
    phases = if has_evidence?(entry), do: ["Share Evidence" | phases], else: phases

    Enum.uniq(phases)
  end

  defp has_code_changes?(entry) do
    has_pr?(entry) or "Implement" in Map.get(entry, :phases_seen, [])
  end

  defp has_pr?(entry), do: Map.get(entry, :pr_url) != nil

  defp has_screenshots?(entry) do
    length(Map.get(entry, :screenshot_urls, [])) > 0
  end

  defp has_evidence?(entry) do
    has_screenshots?(entry) and "Share Evidence" in Map.get(entry, :phases_seen, [])
  end
end
