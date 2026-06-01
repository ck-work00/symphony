defmodule SymphonyElixir.Claude.TmuxCLITest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.TmuxCLI
  alias SymphonyElixir.Config

  describe "session_jsonl_path/1" do
    test "returns :not_found when no JSONL exists for the session id" do
      assert {:error, :not_found} = TmuxCLI.session_jsonl_path("00000000-no-such-session")
    end

    test "finds the JSONL by its unique filename regardless of project-dir escaping" do
      session_id = "test-#{System.unique_integer([:positive])}"
      base = Path.expand(Config.claude_tmux_jsonl_base_path())

      # A project dir whose name contains characters Claude Code's escaping would
      # mangle (underscores -> dashes). Find-by-filename must not care.
      project_dir = Path.join(base, "-Test-ck-code-some_repo_#{System.unique_integer([:positive])}")
      jsonl = Path.join(project_dir, "#{session_id}.jsonl")
      File.mkdir_p!(project_dir)
      File.write!(jsonl, "")
      on_exit(fn -> File.rm_rf!(project_dir) end)

      assert {:ok, ^jsonl} = TmuxCLI.session_jsonl_path(session_id)
    end
  end

  describe "await_jsonl/2" do
    test "returns :not_found after the timeout when the file never appears" do
      assert {:error, :not_found} =
               TmuxCLI.await_jsonl("never-#{System.unique_integer([:positive])}",
                 poll_interval_ms: 10,
                 timeout_ms: 50
               )
    end

    test "returns {:ok, path} once the file appears" do
      session_id = "await-#{System.unique_integer([:positive])}"
      base = Path.expand(Config.claude_tmux_jsonl_base_path())
      project_dir = Path.join(base, "-Test-await-#{System.unique_integer([:positive])}")
      jsonl = Path.join(project_dir, "#{session_id}.jsonl")
      File.mkdir_p!(project_dir)
      File.write!(jsonl, "")
      on_exit(fn -> File.rm_rf!(project_dir) end)

      assert {:ok, ^jsonl} =
               TmuxCLI.await_jsonl(session_id, poll_interval_ms: 10, timeout_ms: 200)
    end
  end

  describe "start_session/3 workspace validation" do
    test "rejects a workspace outside the configured roots" do
      assert {:error, {:invalid_workspace_cwd, :outside_root}} =
               TmuxCLI.start_session("/etc", "irrelevant-session-id")
    end

    test "rejects a workspace that is not a directory" do
      assert {:error, {:invalid_workspace_cwd, :not_a_directory}} =
               TmuxCLI.start_session(
                 Path.join(Config.workspace_root(), "does-not-exist-#{System.unique_integer([:positive])}"),
                 "irrelevant-session-id"
               )
    end
  end
end
