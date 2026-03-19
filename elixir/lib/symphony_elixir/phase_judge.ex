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

    Logger.info("PhaseJudge: issue=#{running_entry[:identifier]} completed=#{inspect(completed)} missing=#{inspect(missing)}")

    if missing == [] do
      :done
    else
      {:retask, missing, completed}
    end
  end

  @doc "Returns the canonical phase order."
  def phases_in_order, do: @phases_in_order

  # ---------------------------------------------------------------------------
  # Phase detection — uses concrete signals from the running entry
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
