defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from Claude Code's stream-json output.
  """

  require Logger

  @doc """
  Parse a single JSON line from stdout. Returns {:ok, event_map} or {:error, reason}.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, normalize_event(payload)}
      {:ok, _other} -> {:error, {:not_a_map, line}}
      {:error, reason} -> {:error, {:json_parse_error, reason, line}}
    end
  end

  @doc """
  Extract session_id from a parsed event, if present.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(%{session_id: id}) when is_binary(id), do: id
  def extract_session_id(_event), do: nil

  @doc """
  Extract usage data from a parsed event.
  Returns a map with :input_tokens, :output_tokens, :total_tokens or nil.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    usage =
      Map.get(event, "usage") ||
        Map.get(event, :usage) ||
        nested_message_usage(event)

    normalize_usage(usage)
  end

  defp nested_message_usage(event) do
    msg = Map.get(event, "message") || Map.get(event, :message)
    if is_map(msg), do: Map.get(msg, "usage") || Map.get(msg, :usage)
  end

  defp normalize_usage(%{} = usage) do
    input = integer_field(usage, ["input_tokens", :input_tokens])
    output = integer_field(usage, ["output_tokens", :output_tokens])
    total = integer_field(usage, ["total_tokens", :total_tokens])

    if input || output || total do
      %{
        input_tokens: input || 0,
        output_tokens: output || 0,
        total_tokens: total || (input || 0) + (output || 0)
      }
    end
  end

  defp normalize_usage(_), do: nil

  defp normalize_event(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)
    Map.put(payload, :event_type, categorize_type(type, payload))
  end

  # Only the "init" system event signals the actual start of a session.
  defp categorize_type("system", payload) do
    subtype = Map.get(payload, "subtype") || Map.get(payload, :subtype)
    if subtype == "init", do: :session_started, else: :system
  end

  defp categorize_type("assistant", _payload), do: :assistant
  defp categorize_type("tool", _payload), do: :tool_use
  defp categorize_type("user", _payload), do: :tool_result
  defp categorize_type("result", _payload), do: :result
  defp categorize_type("rate_limit_event", _payload), do: :rate_limit
  defp categorize_type(_, _payload), do: :unknown

  # ---------------------------------------------------------------------------
  # Phase inference
  # ---------------------------------------------------------------------------

  @doc """
  Infer the workflow phase from an event.

  For assistant events: checks text for explicit phase headers ("### Phase N: Name"),
  and infers phase from tool_use names/inputs (Read/Grep = Investigate,
  Edit/Write = Implement, mix test/check = Test, gh pr/git push = Ship).

  For tool_result events: checks stdout for PR creation output.

  Returns a short label or nil.
  """
  @spec extract_phase(map()) :: String.t() | nil
  def extract_phase(%{event_type: :assistant} = event) do
    text = extract_text_content(event)

    # Priority 1: Explicit SYMPHONY_PHASE marker
    detect_symphony_phase(text) ||
      # Priority 2: Markdown phase headers
      detect_phase_header(text) ||
      # Priority 3: Tool-based heuristic
      (event |> extract_tool_uses() |> infer_phase_from_tools())
  end

  def extract_phase(_event), do: nil

  defp extract_text_content(event) do
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      %{type: "text", text: text} -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  # Match "SYMPHONY_PHASE: Name" markers
  @symphony_phase_regex ~r/SYMPHONY_PHASE:\s*(.+)/

  defp detect_symphony_phase(""), do: nil

  defp detect_symphony_phase(text) do
    case Regex.run(@symphony_phase_regex, text) do
      [_, phase_name] -> phase_name |> String.trim() |> String.slice(0, 30)
      nil -> nil
    end
  end

  # Match "### Phase N: Name" or "## Phase: Name" patterns
  @phase_header_regex ~r/\#{2,3}\s+Phase\s*(?:\d+)?[:\s]+(.+)/i

  defp detect_phase_header(""), do: nil

  defp detect_phase_header(text) do
    case Regex.run(@phase_header_regex, text) do
      [_, phase_name] -> phase_name |> String.trim() |> String.slice(0, 30)
      nil -> nil
    end
  end

  defp extract_tool_uses(event) do
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "tool_use", "name" => name, "input" => input} -> [{name, input}]
      %{"type" => "tool_use", "name" => name} -> [{name, %{}}]
      _ -> []
    end)
  end

  @ship_tools ~w(Agent)
  @test_commands ~w(mix\ test mix\ check npm\ run\ test)
  @investigate_tools ~w(Read Grep Glob WebFetch WebSearch)
  @implement_tools ~w(Edit Write MultiEdit)

  defp infer_phase_from_tools([]), do: nil

  defp infer_phase_from_tools(tool_uses) do
    Enum.find_value(tool_uses, fn {name, input} ->
      command = get_command(input)

      cond do
        # Ship: gh pr create, git push
        name == "Bash" and command_matches?(command, ["gh pr create", "git push"]) ->
          "Ship"

        # Test: mix test, mix check, playwright
        name == "Bash" and command_matches?(command, @test_commands) ->
          "Test"

        name == "Bash" and String.contains?(command, "playwright") ->
          "Test"

        String.starts_with?(name, "mcp__playwright") or
            String.starts_with?(name, "mcp__plugin_playwright") ->
          "Test"

        # Ship: Agent tool (often used for PR creation)
        name in @ship_tools and agent_is_pr?(input) ->
          "Ship"

        # Implement: Edit, Write
        name in @implement_tools ->
          "Implement"

        # Investigate: Read, Grep, Glob, search
        name in @investigate_tools ->
          "Investigate"

        # Bash with curl to Linear API = sharing evidence
        name == "Bash" and command_matches?(command, ["curl", "linear.app"]) ->
          "Share Evidence"

        true ->
          nil
      end
    end)
  end

  defp get_command(input) when is_map(input) do
    Map.get(input, "command") || Map.get(input, :command) || ""
  end

  defp get_command(_), do: ""

  defp command_matches?(command, patterns) when is_binary(command) do
    Enum.any?(patterns, &String.contains?(command, &1))
  end

  defp agent_is_pr?(input) when is_map(input) do
    prompt = Map.get(input, "prompt") || Map.get(input, :prompt) || ""
    desc = Map.get(input, "description") || Map.get(input, :description) || ""
    combined = prompt <> " " <> desc

    String.contains?(String.downcase(combined), "pr") or
      String.contains?(String.downcase(combined), "pull request")
  end

  defp agent_is_pr?(_), do: false

  # ---------------------------------------------------------------------------
  # PR URL extraction
  # ---------------------------------------------------------------------------

  @doc """
  Extract a GitHub PR URL from any event's text content.

  Checks:
  - Assistant message text (agent mentions the PR URL after creating it)
  - Tool result stdout (output of `gh pr create`)
  - Result event text

  Returns the first match or nil.
  """
  @spec extract_pr_url(map()) :: String.t() | nil
  def extract_pr_url(%{event_type: :assistant} = event) do
    event |> extract_text_content() |> detect_pr_url()
  end

  def extract_pr_url(%{event_type: :tool_result} = event) do
    event |> extract_tool_result_text() |> detect_pr_url()
  end

  def extract_pr_url(%{event_type: :result} = event) do
    result = Map.get(event, "result") || Map.get(event, :result) || ""
    if is_binary(result), do: detect_pr_url(result), else: nil
  end

  def extract_pr_url(_event), do: nil

  defp extract_tool_result_text(event) do
    # tool_use_result.stdout has the raw command output
    tool_result = Map.get(event, "tool_use_result") || %{}
    stdout = Map.get(tool_result, "stdout") || Map.get(tool_result, :stdout) || ""

    # Also check message.content[].content for tool_result blocks
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    result_text =
      content
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "tool_result", "content" => c} when is_binary(c) -> [c]
        _ -> []
      end)
      |> Enum.join("\n")

    case {stdout, result_text} do
      {"", ""} -> ""
      {s, ""} -> s
      {"", r} -> r
      {s, r} -> s <> "\n" <> r
    end
  end

  @pr_url_regex ~r{https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+}

  defp detect_pr_url(""), do: nil

  defp detect_pr_url(text) do
    case Regex.run(@pr_url_regex, text) do
      [url] -> url
      nil -> nil
    end
  end

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        v when is_integer(v) and v >= 0 -> v
        _ -> nil
      end
    end)
  end
end
