defmodule SymphonyElixir.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamParser

  defp assistant_text_event(text) do
    %{"message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    |> Map.put(:event_type, :assistant)
  end

  defp assistant_tool_event(tool_name, input) do
    %{"message" => %{"content" => [%{"type" => "tool_use", "name" => tool_name, "input" => input}]}}
    |> Map.put(:event_type, :assistant)
  end

  defp tool_result_event(stdout, content \\ nil) do
    event = %{
      "tool_use_result" => %{"stdout" => stdout},
      "message" => %{
        "content" =>
          if content do
            [%{"type" => "tool_result", "content" => content}]
          else
            []
          end
      }
    }

    Map.put(event, :event_type, :tool_result)
  end

  describe "extract_phase/1" do
    test "extracts explicit phase header from assistant text" do
      event = assistant_text_event("### Phase 1: Investigate\n\nLet me look at the code...")
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Investigate from Read tool" do
      event = assistant_tool_event("Read", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Investigate from Grep tool" do
      event = assistant_tool_event("Grep", %{"pattern" => "defmodule"})
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Implement from Edit tool" do
      event = assistant_tool_event("Edit", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Implement"
    end

    test "infers Implement from Write tool" do
      event = assistant_tool_event("Write", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Implement"
    end

    test "infers Test from mix test command" do
      event = assistant_tool_event("Bash", %{"command" => "direnv exec . mix test"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Test from mix check command" do
      event = assistant_tool_event("Bash", %{"command" => "direnv exec . mix check"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Test from Playwright MCP tool" do
      event = assistant_tool_event("mcp__playwright__browser_navigate", %{"url" => "http://localhost:3005"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Ship from gh pr create command" do
      event = assistant_tool_event("Bash", %{"command" => "gh pr create --title 'Fix' --body 'Done'"})
      assert StreamParser.extract_phase(event) == "Ship"
    end

    test "infers Ship from git push command" do
      event = assistant_tool_event("Bash", %{"command" => "git push -u origin gea-2174"})
      assert StreamParser.extract_phase(event) == "Ship"
    end

    test "extracts SYMPHONY_PHASE marker with highest priority" do
      event = assistant_text_event("SYMPHONY_PHASE: Investigate\n\nLet me look at the code...")
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "SYMPHONY_PHASE takes priority over tool-based inference" do
      # Event has both a SYMPHONY_PHASE marker and an Edit tool use
      event = %{
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "SYMPHONY_PHASE: Test"},
            %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "/f.ex"}}
          ]
        }
      }
      |> Map.put(:event_type, :assistant)

      # Should return "Test" from SYMPHONY_PHASE, not "Implement" from Edit
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "SYMPHONY_PHASE handles all standard phases" do
      for phase <- ["Investigate", "Plan", "Implement", "Test", "Evidence", "Ship"] do
        event = assistant_text_event("SYMPHONY_PHASE: #{phase}")
        assert StreamParser.extract_phase(event) == phase
      end
    end

    test "SYMPHONY_PHASE trims whitespace" do
      event = assistant_text_event("SYMPHONY_PHASE:   Ship  ")
      assert StreamParser.extract_phase(event) == "Ship"
    end

    test "returns nil for non-assistant events" do
      event = %{"message" => %{"content" => []}} |> Map.put(:event_type, :tool_result)
      assert StreamParser.extract_phase(event) == nil
    end

    test "returns nil when no phase can be inferred" do
      event = assistant_tool_event("Bash", %{"command" => "ls -la"})
      assert StreamParser.extract_phase(event) == nil
    end
  end

  describe "extract_pr_url/1" do
    test "extracts PR URL from assistant text" do
      event = assistant_text_event("PR created: https://github.com/GearFlowDev/gf_procurement/pull/801")
      assert StreamParser.extract_pr_url(event) == "https://github.com/GearFlowDev/gf_procurement/pull/801"
    end

    test "extracts PR URL from tool_result stdout" do
      event = tool_result_event("https://github.com/org/repo/pull/42\n")
      assert StreamParser.extract_pr_url(event) == "https://github.com/org/repo/pull/42"
    end

    test "extracts PR URL from tool_result content" do
      event = tool_result_event("", "https://github.com/org/repo/pull/99")
      assert StreamParser.extract_pr_url(event) == "https://github.com/org/repo/pull/99"
    end

    test "returns nil for non-matching text" do
      event = assistant_text_event("No PR here, just working on code.")
      assert StreamParser.extract_pr_url(event) == nil
    end

    test "returns nil for system events" do
      event = %{"content" => "https://github.com/org/repo/pull/1"} |> Map.put(:event_type, :system)
      assert StreamParser.extract_pr_url(event) == nil
    end
  end
end
