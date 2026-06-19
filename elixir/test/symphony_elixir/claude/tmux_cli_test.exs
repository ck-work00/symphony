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

  describe "reap_orphan_sessions/1" do
    @describetag :tmux

    # Tagged :tmux — these drive a real tmux server. Exclude with
    # `--exclude tmux` on hosts without tmux installed.
    setup do
      # Use a unique, test-only prefix so we never touch real symphony sessions.
      prefix = "symphonytest#{System.unique_integer([:positive])}"
      {:ok, prefix: prefix}
    end

    defp kill_on_exit(name) do
      on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true) end)
    end

    test "kills sessions matching the prefix and reports them", %{prefix: prefix} do
      name = "#{prefix}-#{System.unique_integer([:positive])}"
      kill_on_exit(name)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == [name]
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)
      assert code != 0
    end

    test "leaves sessions that do not match the prefix", %{prefix: prefix} do
      other = "unrelated-#{System.unique_integer([:positive])}"
      kill_on_exit(other)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", other], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == []
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", other], stderr_to_stdout: true)
    end

    test "removes the reaped session's prompt temp files", %{prefix: prefix} do
      session_id = "#{System.unique_integer([:positive])}"
      name = "#{prefix}-#{session_id}"
      kill_on_exit(name)
      tmp = Path.join(System.tmp_dir!(), "symphony-#{session_id}-1.txt")
      File.write!(tmp, "prompt")
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == [name]
      refute File.exists?(tmp)
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

  describe "reap_orphan_sessions_except/2 and kill_by_session_id/1" do
    @describetag :tmux

    setup do
      prefix = "symphonytest#{System.unique_integer([:positive])}"
      {:ok, prefix: prefix}
    end

    defp new_session(name) do
      on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true) end)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)
      name
    end

    test "keeps sessions whose session_id is in the keep set", %{prefix: prefix} do
      keep_id = "#{System.unique_integer([:positive])}"
      drop_id = "#{System.unique_integer([:positive])}"
      keep_name = new_session("#{prefix}-#{keep_id}")
      drop_name = new_session("#{prefix}-#{drop_id}")

      assert TmuxCLI.reap_orphan_sessions_except([keep_id], prefix: prefix) == [drop_name]
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", keep_name], stderr_to_stdout: true)
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", drop_name], stderr_to_stdout: true)
      assert code != 0
    end

    test "does not reap a young session when min_age_seconds is set", %{prefix: prefix} do
      # The race guard: a just-launched worker's session exists before its
      # session_id reaches the running map, so a grace window must spare it.
      name = new_session("#{prefix}-#{System.unique_integer([:positive])}")

      assert TmuxCLI.reap_orphan_sessions_except([], prefix: prefix, min_age_seconds: 120) == []
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)

      # Same session reaps once the age floor is removed.
      assert TmuxCLI.reap_orphan_sessions_except([], prefix: prefix) == [name]
    end

    test "kill_by_session_id kills the matching session and is idempotent" do
      # kill_by_session_id derives the name from the configured prefix, so build
      # the session under that same prefix (unique id avoids any real session).
      prefix = Config.claude_tmux_session_prefix()
      session_id = "killtest-#{System.unique_integer([:positive])}"
      name = new_session("#{prefix}-#{session_id}")

      assert :ok = TmuxCLI.kill_by_session_id(session_id)
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)
      assert code != 0
      # Idempotent: killing an already-gone session is still :ok.
      assert :ok = TmuxCLI.kill_by_session_id(session_id)
      assert :ok = TmuxCLI.kill_by_session_id(nil)
    end
  end
end
