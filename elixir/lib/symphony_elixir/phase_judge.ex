defmodule SymphonyElixir.PhaseJudge do
  @moduledoc """
  External judge that evaluates which workflow phases an agent completed.

  Uses external evidence — git state, PRs, CI, Linear comments — as the
  primary source of truth. Workers never self-report phase status.

  Phases are dispatched one at a time. After each agent run, the judge
  determines which phase to dispatch next.
  """

  require Logger

  alias SymphonyElixir.History

  @phases_in_order ["Investigate", "Implement", "Share Evidence", "Simplify"]

  # Maximum total runs per issue before we stop retrying.
  @max_runs_per_issue 12

  @type assessment :: :done | :max_runs_reached | {:retask, missing :: [String.t()], completed :: [String.t()]}

  @doc """
  Assess a completed running entry using external evidence.

  Takes the running entry and an optional evaluation result from the Evaluator.
  Returns `:done`, `:max_runs_reached`, or `{:retask, missing, completed}`.

  In the discrete-phase model, `{:retask, missing, completed}` always means
  "dispatch the first element of missing next."
  """
  @spec assess(map(), map() | nil) :: assessment()
  def assess(running_entry, eval_result \\ nil) do
    identifier = running_entry[:identifier]
    summary = History.issue_summary(identifier)

    if summary.total_runs >= @max_runs_per_issue do
      Logger.warning("PhaseJudge: issue=#{identifier} reached #{summary.total_runs} runs (max #{@max_runs_per_issue}), stopping")
      :max_runs_reached
    else
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
        |> then(fn p -> if pr_url != nil, do: ["Investigate", "Implement"] ++ p, else: p end)
        |> then(fn p -> if summary.has_evidence, do: ["Share Evidence"] ++ p, else: p end)

      # Run live evidence check for phases that can't be determined from history alone
      workspace_path = resolve_workspace(identifier)
      live_evidence = if workspace_path, do: live_evidence_check(workspace_path, issue), else: []

      completed = Enum.uniq(from_history ++ from_external ++ live_evidence)
      missing = @phases_in_order -- completed

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

    # Investigate: plan posted to Linear
    phases = if eval[:plan_posted], do: ["Investigate" | phases], else: phases

    # Implement: PR created with files changed and tests written
    phases =
      if eval[:pr_created] and eval[:files_changed] > 0 do
        p = ["Implement" | phases]
        # If there's also a plan, investigate is done too
        if eval[:plan_posted], do: p, else: ["Investigate" | p]
      else
        phases
      end

    # Share Evidence: Linear comment with screenshots/evidence posted
    phases = if eval[:evidence_posted], do: ["Share Evidence" | phases], else: phases

    # Simplify: simplification commit or "no changes needed" comment
    phases = if eval[:simplify_done], do: ["Simplify" | phases], else: phases

    Enum.uniq(phases)
  end

  defp summarize_evidence(nil), do: %{}

  defp summarize_evidence(eval) do
    %{
      files_changed: eval[:files_changed] || 0,
      pr_created: eval[:pr_created] || false,
      tests_written: eval[:tests_written] || false,
      evidence_posted: eval[:evidence_posted] || false,
      plan_posted: eval[:plan_posted] || false,
      simplify_done: eval[:simplify_done] || false,
      ci_status: eval[:ci_status] || "none"
    }
  end

  # ---------------------------------------------------------------------------
  # History-based phase detection (prior runs)
  # ---------------------------------------------------------------------------

  defp phases_from_history(summary) do
    phases = []

    event_types = summary.events |> Enum.map(& &1.event_type) |> MapSet.new()

    # PR or first edit implies Investigate + Implement done
    phases =
      if MapSet.member?(event_types, "milestone_pr_created") or summary.has_pr do
        ["Investigate", "Implement" | phases]
      else
        if MapSet.member?(event_types, "milestone_first_edit") do
          ["Investigate" | phases]
        else
          phases
        end
      end

    # Evidence in Linear
    phases = if length(summary.screenshots) > 0 or summary.has_evidence, do: ["Share Evidence" | phases], else: phases

    Enum.uniq(phases)
  end

  # ---------------------------------------------------------------------------
  # Evidence checks — probes Linear for screenshots/comments
  # ---------------------------------------------------------------------------

  @doc "Check whether the Linear issue has screenshot evidence in its comments."
  @spec check_linear_evidence(map()) :: boolean()
  def check_linear_evidence(%{id: issue_id}) when is_binary(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
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

  # Quick workspace resolution for pre-dispatch checks
  defp resolve_workspace(identifier) when is_binary(identifier) do
    workspace = Path.join(SymphonyElixir.Config.workspace_root(), identifier)
    slot_file = Path.join(workspace, ".symphony_slot")

    case File.read(slot_file) do
      {:ok, content} ->
        case Regex.run(~r/DIRECTORY=(.+)/, content) do
          [_, dir] ->
            resolved = String.trim(dir)
            if File.dir?(resolved), do: resolved

          _ -> nil
        end

      _ -> nil
    end
  end

  defp resolve_workspace(_), do: nil

  # Check live workspace state for phases that need it
  defp live_evidence_check(workspace_path, issue) do
    phases = []

    # Simplify: 2+ commits on branch
    phases =
      case System.cmd("sh", ["-c", "git log --oneline origin/main..HEAD 2>/dev/null"], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} ->
          commits = output |> String.split("\n", trim: true) |> length()
          if commits >= 2, do: ["Simplify" | phases], else: phases

        _ -> phases
      end

    # Plan posted: check Linear for requirements comment
    issue_id = Map.get(issue, :id)

    phases =
      if is_binary(issue_id) do
        case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
          {:ok, comments} ->
            all_text = comments |> Enum.map(& &1.body) |> Enum.join("\n")

            p = phases
            p = if String.contains?(all_text, "## Requirements") or String.contains?(all_text, "- [ ]"), do: ["Investigate" | p], else: p
            p = if String.contains?(all_text, "## Test Results"), do: ["Share Evidence" | p], else: p
            p

          _ -> phases
        end
      else
        phases
      end

    Enum.uniq(phases)
  end
end
