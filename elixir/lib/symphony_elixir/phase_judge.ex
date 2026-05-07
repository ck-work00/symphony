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

  @phases_in_order ["Implement", "Test", "Share Evidence", "Simplify"]

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
    issue = Map.get(running_entry, :issue)
    summary = History.issue_summary(identifier)

    if summary.total_runs >= @max_runs_per_issue do
      Logger.warning("PhaseJudge: issue=#{identifier} reached #{summary.total_runs} runs (max #{@max_runs_per_issue}), stopping")
      :max_runs_reached
    else
      from_history = phases_from_history(summary)
      from_evidence = phases_from_evidence(eval_result)
      completed = Enum.uniq(from_history ++ from_evidence)
      missing = @phases_in_order -- completed

      # Check for unaddressed @agent feedback on Linear — overrides to Implement
      missing = maybe_override_for_feedback(missing, completed, issue, summary)

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
        |> then(fn p -> if pr_url != nil, do: ["Implement"] ++ p, else: p end)
        |> then(fn p -> if summary.has_evidence, do: ["Share Evidence"] ++ p, else: p end)

      # Run live evidence check for phases that can't be determined from history alone
      workspace_path = resolve_workspace(identifier)
      live_evidence = if workspace_path, do: live_evidence_check(workspace_path, issue), else: []

      completed = Enum.uniq(from_history ++ from_external ++ live_evidence)
      missing = @phases_in_order -- completed

      # Check for unaddressed @agent feedback on Linear — overrides to Implement
      missing = maybe_override_for_feedback(missing, completed, issue, summary)

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
  # @agent feedback override
  # ---------------------------------------------------------------------------

  # If there's an unaddressed @agent comment on Linear (newer than the last
  # agent run), override the next phase to Implement. Linear operator feedback
  # is the highest priority signal.
  defp maybe_override_for_feedback(missing, completed, issue, summary) do
    if "Implement" in completed and has_unaddressed_agent_feedback?(issue, summary) do
      Logger.info("PhaseJudge: unaddressed @agent feedback found, routing to Implement")
      # Force Implement back into missing as the first phase
      ["Implement" | (missing -- ["Implement"])]
    else
      missing
    end
  end

  defp has_unaddressed_agent_feedback?(nil, _summary), do: false

  defp has_unaddressed_agent_feedback?(issue, summary) do
    issue_id = Map.get(issue, :id)
    if not is_binary(issue_id), do: false, else: do_check_agent_feedback(issue_id, summary)
  end

  defp do_check_agent_feedback(issue_id, summary) do
    # Fetch @agent-prefixed comments (human-to-agent messages)
    case SymphonyElixir.Linear.Client.fetch_issue_comments(issue_id) do
      {:ok, comments} when comments != [] ->
        # Find the latest @agent comment
        latest_feedback =
          comments
          |> Enum.filter(fn c -> c.created_at != nil end)
          |> Enum.max_by(fn c -> DateTime.to_unix(c.created_at) end, fn -> nil end)

        if latest_feedback do
          # Check if this feedback is newer than the last completed run
          last_run_at = summary.last_completed_at

          if last_run_at == nil or DateTime.compare(latest_feedback.created_at, last_run_at) == :gt do
            Logger.info("PhaseJudge: @agent feedback at #{DateTime.to_iso8601(latest_feedback.created_at)}: #{String.slice(latest_feedback.body, 0, 100)}")
            true
          else
            false
          end
        else
          false
        end

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence-based phase detection (current run)
  # ---------------------------------------------------------------------------

  defp phases_from_evidence(nil), do: []

  defp phases_from_evidence(eval) do
    phases = []

    # Implement: PR created with files changed
    phases =
      if eval[:pr_created] and eval[:files_changed] > 0 do
        ["Implement" | phases]
      else
        phases
      end

    # Test: tester sub-agent posted an APPROVE Tester Report
    phases = if eval[:tester_approved], do: ["Test" | phases], else: phases

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
      tester_approved: eval[:tester_approved] || false,
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

    # PR existence implies Implement done
    phases =
      if MapSet.member?(event_types, "milestone_pr_created") or summary.has_pr do
        ["Implement" | phases]
      else
        phases
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

    # Test + Share Evidence: check Linear for tester report and audit/test-results comments
    issue_id = Map.get(issue, :id)

    phases =
      if is_binary(issue_id) do
        case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
          {:ok, comments} ->
            all_text = comments |> Enum.map(& &1.body) |> Enum.join("\n")

            p = phases
            p = if tester_approved?(all_text), do: ["Test" | p], else: p
            p =
              if String.contains?(all_text, "## Test Results") or
                   String.contains?(all_text, "## Contract Audit"),
                 do: ["Share Evidence" | p],
                 else: p

            p

          _ -> phases
        end
      else
        phases
      end

    Enum.uniq(phases)
  end

  # A Tester Report counts as APPROVE only if it cleanly says so. Hybrid
  # forms the tester sub-agent has actually emitted in the wild —
  # `Recommendation: ⚠ APPROVE-AFTER-PUSH`, `APPROVE-WITH-CONDITIONS`,
  # `APPROVE-PENDING-...` — must NOT count as APPROVE; they mean the work
  # has gaps the tester can't close itself, and the loop needs to bounce
  # back to Implement. Otherwise PhaseJudge marks Test done on a
  # substring match and the orchestrator's tester→Implement override
  # in maybe_attach_plan_assignment never gets a chance to fire.
  defp tester_approved?(text) do
    String.contains?(text, "## Tester Report") and
      Regex.match?(
        ~r/Recommendation:\s*(?:\*\*\s*)?APPROVE(?:\s*\*\*)?(?=\s|$|\.)/m,
        text
      ) and
      not Regex.match?(
        ~r/Recommendation:[^\n]*APPROVE[-\s]+(?:AFTER|WITH|PENDING|SUBJECT|ONCE|IF|MODULO)/i,
        text
      )
  end
end
