defmodule SymphonyElixir.PhaseJudge do
  @moduledoc """
  External judge that evaluates which workflow phases an agent completed.

  Uses external evidence — git state, PRs, CI, Linear comments — as the
  primary source of truth. The evaluator gathers this evidence after each
  agent run. The judge maps evidence to phase completion.

  Workers never self-report phase status. The judge decides.
  """

  require Logger

  alias SymphonyElixir.History

  @phases_in_order ["Investigate", "Implement", "Test", "Ship", "Share Evidence"]

  # Maximum total runs per issue before we stop retrying.
  @max_runs_per_issue 8

  @type assessment :: :done | :max_runs_reached | {:retask, missing :: [String.t()], completed :: [String.t()]}

  @doc """
  Assess a completed running entry using external evidence.

  Takes the running entry and an optional evaluation result from the Evaluator.
  Maps evidence to phase completion, merges with history from prior runs.

  Returns `:done`, `:max_runs_reached`, or `{:retask, missing, completed}`.
  """
  @spec assess(map(), map() | nil) :: assessment()
  def assess(running_entry, eval_result \\ nil) do
    identifier = running_entry[:identifier]
    summary = History.issue_summary(identifier)

    # Hard stop: too many runs means something is wrong
    if summary.total_runs >= @max_runs_per_issue do
      Logger.warning("PhaseJudge: issue=#{identifier} reached #{summary.total_runs} runs (max #{@max_runs_per_issue}), stopping")
      :max_runs_reached
    else
      # Build completed phases from history + current evidence
      from_history = phases_from_history(summary)
      from_evidence = phases_from_evidence(eval_result)
      completed = Enum.uniq(from_history ++ from_evidence)
      missing = @phases_in_order -- completed

      Logger.info("PhaseJudge: issue=#{identifier} completed=#{inspect(completed)} missing=#{inspect(missing)} total_runs=#{summary.total_runs} evidence=#{inspect(summarize_evidence(eval_result))}")

      if missing == [] do
        :done
      else
        {:retask, missing, completed}
      end
    end
  end

  @doc """
  Pre-dispatch assessment using local history and external signals.

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
  # Evidence-based phase detection (current run)
  # ---------------------------------------------------------------------------

  defp phases_from_evidence(nil), do: []

  defp phases_from_evidence(eval) do
    phases = []

    # Investigate: branch exists and has changes (agent read the issue and started work)
    phases = if eval[:files_changed] > 0 or eval[:branch_pushed] or eval[:pr_created], do: ["Investigate" | phases], else: phases

    # Implement: files changed against main
    phases = if eval[:files_changed] > 0, do: ["Implement" | phases], else: phases

    # Test: test files exist in the diff
    phases = if eval[:tests_written], do: ["Test" | phases], else: phases

    # Ship: PR created
    phases = if eval[:pr_created], do: ["Ship" | phases], else: phases

    # Share Evidence: Linear comment with screenshots posted
    phases = if eval[:evidence_posted], do: ["Share Evidence" | phases], else: phases

    Enum.uniq(phases)
  end

  defp summarize_evidence(nil), do: %{}

  defp summarize_evidence(eval) do
    %{
      files_changed: eval[:files_changed] || 0,
      pr_created: eval[:pr_created] || false,
      tests_written: eval[:tests_written] || false,
      evidence_posted: eval[:evidence_posted] || false,
      branch_pushed: eval[:branch_pushed] || false,
      ci_status: eval[:ci_status] || "none"
    }
  end

  # ---------------------------------------------------------------------------
  # History-based phase detection (prior runs)
  # ---------------------------------------------------------------------------

  defp phases_from_history(summary) do
    phases = []

    # Milestones from events and eval results across all runs
    event_types = summary.events |> Enum.map(& &1.event_type) |> MapSet.new()

    phases = if MapSet.member?(event_types, "milestone_first_edit"), do: ["Investigate", "Implement" | phases], else: phases
    phases = if MapSet.member?(event_types, "milestone_tests_run") or summary.has_tests, do: ["Test" | phases], else: phases
    phases = if MapSet.member?(event_types, "milestone_pr_created") or summary.has_pr, do: ["Ship", "Investigate", "Implement" | phases], else: phases
    phases = if length(summary.screenshots) > 0 or summary.has_evidence, do: ["Share Evidence" | phases], else: phases

    Enum.uniq(phases)
  end

  # ---------------------------------------------------------------------------
  # Evidence checks — probes Linear for screenshots/comments
  # ---------------------------------------------------------------------------

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
end
