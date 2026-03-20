defmodule SymphonyElixir.PhaseJudge do
  @moduledoc """
  External judge that evaluates which workflow phases an agent completed.

  After each agent run, the orchestrator calls `assess/1` to decide whether the
  run is done or needs a targeted retask on only the missing phases. This avoids
  two problems: (1) the agent judging itself, and (2) full restarts that repeat
  completed work.
  """

  require Logger

  @phases_in_order ["Investigate", "Implement", "Test", "Ship", "Share Evidence"]

  @type assessment :: :done | {:retask, missing :: [String.t()], completed :: [String.t()]}

  @doc """
  Assess a completed running entry and decide whether to retask.

  Returns `:done` if all required phases are complete, or
  `{:retask, missing_phases, completed_phases}` if the agent needs to continue
  with only the missing phases.
  """
  @spec assess(map()) :: assessment()
  def assess(running_entry) do
    completed = detect_completed_phases(running_entry)
    missing = @phases_in_order -- completed

    # If only Test/Share Evidence are missing, check Linear directly —
    # the agent may have posted evidence via curl without the stream parser
    # capturing the URLs in screenshot_urls.
    {missing, completed} =
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

    Logger.info("PhaseJudge: issue=#{running_entry[:identifier]} completed=#{inspect(completed)} missing=#{inspect(missing)}")

    if missing == [] do
      :done
    else
      {:retask, missing, completed}
    end
  end

  @doc """
  Pre-dispatch assessment: decide whether to dispatch an issue that may already
  have work in progress (PR, evidence, etc.).

  Returns:
  - `:done` — all phases complete, don't dispatch
  - `{:retask, missing, completed}` — dispatch with targeted prompt
  - `:fresh` — no prior work detected, dispatch normally
  """
  @spec pre_dispatch_assess(map(), String.t() | nil) :: :fresh | assessment()
  def pre_dispatch_assess(issue, pr_url) do
    if pr_url == nil do
      :fresh
    else
      # PR exists — check what else is done
      evidence_posted = check_linear_evidence(issue)

      completed = ["Investigate", "Implement", "Ship"]
      completed = if evidence_posted, do: completed ++ ["Test", "Share Evidence"], else: completed

      missing = @phases_in_order -- completed

      Logger.info("PhaseJudge pre-dispatch: issue=#{issue_id(issue)} pr=#{pr_url} evidence=#{evidence_posted} completed=#{inspect(completed)} missing=#{inspect(missing)}")

      if missing == [] do
        :done
      else
        {:retask, missing, completed}
      end
    end
  end

  @doc "Returns the canonical phase order."
  def phases_in_order, do: @phases_in_order

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

  # ---------------------------------------------------------------------------
  # Post-run phase detection — uses concrete signals from the running entry
  # ---------------------------------------------------------------------------

  defp detect_completed_phases(entry) do
    phases = []

    # Investigate + Implement: if the agent made commits (has phases_seen indicating progress)
    phases_seen = Map.get(entry, :phases_seen, [])

    phases =
      if "Investigate" in phases_seen or has_code_changes?(entry) do
        ["Investigate" | phases]
      else
        phases
      end

    phases =
      if "Implement" in phases_seen or has_code_changes?(entry) do
        ["Implement" | phases]
      else
        phases
      end

    # Test: agent visited the Test phase and produced screenshots
    phases =
      if "Test" in phases_seen and has_screenshots?(entry) do
        ["Test" | phases]
      else
        phases
      end

    # Ship: a PR URL was captured
    phases =
      if has_pr?(entry) do
        ["Ship" | phases]
      else
        phases
      end

    # Share Evidence: screenshots were uploaded (screenshot_urls present)
    phases =
      if has_evidence?(entry) do
        ["Share Evidence" | phases]
      else
        phases
      end

    phases
    |> Enum.uniq()
    |> Enum.sort_by(fn phase -> Enum.find_index(@phases_in_order, &(&1 == phase)) end)
  end

  defp has_code_changes?(entry) do
    # If we have a PR or the agent visited Implement, code changes exist
    has_pr?(entry) or "Implement" in Map.get(entry, :phases_seen, [])
  end

  defp has_pr?(entry) do
    Map.get(entry, :pr_url) != nil
  end

  defp has_screenshots?(entry) do
    screenshot_urls = Map.get(entry, :screenshot_urls, [])
    length(screenshot_urls) > 0
  end

  defp has_evidence?(entry) do
    # Evidence = screenshots were uploaded to Linear (captured as screenshot_urls)
    # AND the agent visited the Share Evidence phase
    has_screenshots?(entry) and "Share Evidence" in Map.get(entry, :phases_seen, [])
  end
end
