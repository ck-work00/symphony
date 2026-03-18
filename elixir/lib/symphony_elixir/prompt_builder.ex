defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Workflow.StageLoader

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @doc """
  Builds a continuation prompt for turn N+.
  Uses staged _continuation.md template if available, otherwise falls back to default.
  """
  @spec build_continuation_prompt(map(), pos_integer(), pos_integer(), [map()]) :: String.t()
  def build_continuation_prompt(issue, turn_number, max_turns, comments) do
    stages_dir = Workflow.stages_directory()

    if File.dir?(stages_dir) do
      stages = StageLoader.load_stages(stages_dir)

      case StageLoader.assemble_continuation(stages, turn_number, max_turns, comments) do
        nil -> default_continuation_prompt(issue, turn_number, max_turns, comments)
        prompt -> prompt
      end
    else
      default_continuation_prompt(issue, turn_number, max_turns, comments)
    end
  end

  defp default_continuation_prompt(_issue, turn_number, max_turns, comments) do
    comments_section = format_comments_section(comments)

    """
    Continuation guidance (turn #{turn_number}/#{max_turns}):

    You are on turn #{turn_number} of #{max_turns}. Output SYMPHONY_TASK_COMPLETE on its own line when done. Without it, you will be restarted.

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

  defp format_comments_section([]), do: ""

  defp format_comments_section(comments) do
    formatted =
      comments
      |> Enum.map(fn c ->
        time = if c[:created_at], do: Calendar.strftime(c.created_at, "%H:%M UTC"), else: "?"
        "  [#{time}] #{c[:author]}: #{c[:body]}"
      end)
      |> Enum.join("\n")

    """

    ## New comments on the Linear issue (from your team — read carefully and follow any instructions):
    #{formatted}

    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
