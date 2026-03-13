defmodule SymphonyElixir.Suitability do
  @moduledoc """
  Pre-dispatch screening for Linear issues.

  Checks config-driven rules to skip issues that are clearly unsuitable
  before wasting agent tokens. Skipped issues are logged but don't
  consume agent slots.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @type skip_reason ::
          :excluded_label
          | :no_description
          | :low_priority

  @spec screen(Issue.t()) :: :ok | {:skip, skip_reason()}
  def screen(%Issue{} = issue) do
    rules = Config.suitability_rules()

    cond do
      has_excluded_label?(issue, rules) -> {:skip, :excluded_label}
      missing_description?(issue, rules) -> {:skip, :no_description}
      below_min_priority?(issue, rules) -> {:skip, :low_priority}
      true -> :ok
    end
  end

  defp has_excluded_label?(%Issue{labels: labels}, %{skip_labels: skip_labels})
       when is_list(labels) and is_list(skip_labels) and skip_labels != [] do
    normalized_skip = MapSet.new(skip_labels, &String.downcase/1)
    Enum.any?(labels, &MapSet.member?(normalized_skip, String.downcase(&1)))
  end

  defp has_excluded_label?(_issue, _rules), do: false

  defp missing_description?(%Issue{description: desc}, %{require_description: true}) do
    is_nil(desc) or String.trim(desc) == ""
  end

  defp missing_description?(_issue, _rules), do: false

  defp below_min_priority?(%Issue{priority: priority}, %{min_priority: min})
       when is_integer(priority) and is_integer(min) do
    # Linear priority: 1=urgent, 4=low. "min_priority: 4" means skip priority 4.
    # We skip if priority >= min_priority (lower urgency).
    priority >= min
  end

  defp below_min_priority?(_issue, _rules), do: false
end
