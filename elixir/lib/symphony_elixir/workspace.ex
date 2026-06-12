defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        # If the after_create hook claimed a pool slot, use the slot directory
        # instead of the symphony workspace directory.
        effective_workspace = resolve_slot_workspace(workspace)
        {:ok, effective_workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            # Release any claimed pool slot before removing the workspace
            release_pool_slot(workspace)
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  @spec release_pool_slot(Path.t()) :: :ok
  def release_pool_slot(workspace) do
    slot_file = Path.join(workspace, ".symphony_slot")

    if File.exists?(slot_file) do
      case Config.workspace_hooks()[:before_remove] do
        nil ->
          release_via_default_script(workspace)

        command ->
          # A configured before_remove hook owns slot release. Running the
          # bundled slot-release.sh here instead would bypass the machine's
          # slot protocol (e.g. registry leases on gf_engineering machines)
          # and leave its claim records behind.
          Logger.info("Releasing pool slot via before_remove hook for workspace=#{workspace}")

          run_hook(
            command,
            workspace,
            %{issue_id: nil, issue_identifier: Path.basename(workspace)},
            "before_remove"
          )
          |> ignore_hook_failure()
      end
    else
      # No marker here — the per-poll registry reaper (reap_stale_pool_locks/1)
      # clears any lease that outlives its run, so there's nothing to do inline.
      Logger.debug("No .symphony_slot marker at #{workspace}; registry reaper handles orphan cleanup")
    end

    :ok
  end

  # Grace window so a freshly-claimed lease (written by before_run just before
  # the run registers) is never reaped out from under a starting agent. The
  # primary safety is the not-running check below; this is extra margin.
  @orphan_lease_grace_seconds 120

  defp release_via_default_script(workspace) do
    release_script = scripts_path("slot-release.sh")

    if File.exists?(release_script) do
      Logger.info("Releasing pool slot for workspace=#{workspace}")

      case System.cmd("bash", [release_script, workspace], stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("Pool slot released: #{String.trim(output)}")

        {output, status} ->
          Logger.warning("Pool slot release failed status=#{status}: #{String.trim(output)}")
      end
    end
  end

  @doc """
  Release registry slot leases that no longer back a running issue — the
  orchestrator's per-poll safety net for slots whose run ended without its
  before_remove release firing (e.g. an agent killed on a stall timeout).

  `active_identifiers` is the set of issue identifiers currently running. A lease
  is reaped only when ALL of these hold:

    * Symphony owns it (`owner == "symphony"`). A lease held by an interactive
      human session is NEVER touched — `release_registry_lease/1` does a
      `git reset --hard`, which on a shared machine would wipe a teammate's
      uncommitted work. This owner guard is the primary safety.
    * It sits on a Symphony-designated slot (when `SYMPHONY_PLATFORM_SLOTS` /
      `SYMPHONY_PROCUREMENT_SLOTS` are set — the same designation
      slot-claim-registry.sh honors). Defense in depth on top of the owner guard.
    * Its issue is NOT running — so a re-dispatched issue, already back in
      `running`, is never clobbered — and it was claimed more than the grace
      window ago.

  The freed slot is reset to origin/main so it is immediately reclaimable.
  Best-effort; never raises. Returns the reaped slots.
  """
  @spec reap_stale_pool_locks([String.t()]) :: [String.t()]
  def reap_stale_pool_locks(active_identifiers) when is_list(active_identifiers) do
    active = MapSet.new(active_identifiers)
    now = DateTime.utc_now()

    for {slot_name, lease} <- registry_leases(), reduce: [] do
      reaped ->
        issue = to_string(lease["linear_issue"] || "")

        if symphony_owned?(lease) and eligible_slot?(slot_name) and
             issue != "" and not MapSet.member?(active, issue) and
             lease_claimed_older_than?(lease["claimed"], now, @orphan_lease_grace_seconds) do
          Logger.info("Reaping orphaned slot lease #{slot_name}: issue #{issue} is not running")
          release_registry_lease(slot_name)
          [slot_name | reaped]
        else
          reaped
        end
    end
  rescue
    error ->
      Logger.warning("Orphan lease reap failed: #{Exception.message(error)}")
      []
  end

  # local-dev dir that holds registry/ and the slot working copies.
  defp local_dev_dir do
    case System.get_env("GEARFLOW_WORKSPACE") do
      ws when is_binary(ws) and ws != "" ->
        Path.join(ws, "local-dev")

      _ ->
        # Fallback: SYMPHONY_SCRIPTS is <local-dev>/symphony/elixir/priv/scripts/
        case System.get_env("SYMPHONY_SCRIPTS") do
          s when is_binary(s) and s != "" -> Path.expand(Path.join(s, "../../../.."))
          _ -> nil
        end
    end
  end

  # [{slot_name, lease_map}] for each symphony slot lease in the registry.
  defp registry_leases do
    case local_dev_dir() do
      ld when is_binary(ld) ->
        dir = Path.join(ld, "registry")

        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&Regex.match?(~r/^gf_(?:platform|procurement)-slot\d+\.json$/, &1))
            |> Enum.flat_map(fn file ->
              with {:ok, content} <- File.read(Path.join(dir, file)),
                   {:ok, lease} <- Jason.decode(content) do
                [{String.replace_suffix(file, ".json", ""), lease}]
              else
                _ -> []
              end
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # The reaper only ever touches leases Symphony itself wrote. An interactive
  # human session's lease (any other owner) is off limits — the per-poll
  # `git reset --hard` in release_registry_lease/1 would otherwise wipe a
  # teammate's uncommitted work on a shared machine.
  defp symphony_owned?(lease), do: lease["owner"] == "symphony"

  # When the Symphony-eligible slot set is configured (SYMPHONY_PLATFORM_SLOTS /
  # SYMPHONY_PROCUREMENT_SLOTS — space-separated slot numbers, the same
  # designation slot-claim-registry.sh honors), confine reaping to those slots.
  # An unconfigured repo falls back to the owner guard alone.
  defp eligible_slot?(slot_name) do
    case Regex.run(~r/^gf_(platform|procurement)-slot(\d+)$/, slot_name) do
      [_, repo, num] ->
        case eligible_slot_numbers(repo) do
          [] -> true
          nums -> num in nums
        end

      _ ->
        false
    end
  end

  defp eligible_slot_numbers(repo) do
    case System.get_env("SYMPHONY_#{String.upcase(repo)}_SLOTS") do
      v when is_binary(v) and v != "" -> String.split(v, ~r/\s+/, trim: true)
      _ -> []
    end
  end

  # Remove a slot's registry lease and reset its working copy to origin/main so
  # it is immediately reclaimable. slot_name e.g. "gf_procurement-slot5".
  defp release_registry_lease(slot_name) do
    case local_dev_dir() do
      ld when is_binary(ld) ->
        File.rm(Path.join([ld, "registry", "#{slot_name}.json"]))
        slot_dir = Path.join(ld, slot_name)

        if File.dir?(slot_dir) do
          System.cmd("git", ["-C", slot_dir, "checkout", "--", "."], stderr_to_stdout: true)
          System.cmd("git", ["-C", slot_dir, "checkout", "main"], stderr_to_stdout: true)
          System.cmd("git", ["-C", slot_dir, "reset", "--hard", "origin/main"], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end

    :ok
  end

  defp lease_claimed_older_than?(claimed, now, grace) when is_binary(claimed) do
    case DateTime.from_iso8601(claimed) do
      {:ok, dt, _} -> DateTime.diff(now, dt) > grace
      _ -> true
    end
  end

  defp lease_claimed_older_than?(_claimed, _now, _grace), do: true

  @spec release_pool_slot_for_issue(String.t()) :: :ok
  def release_pool_slot_for_issue(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = workspace_path_for_issue(safe_id)
    release_pool_slot(workspace)
  end

  def release_pool_slot_for_issue(_identifier), do: :ok

  defp resolve_slot_workspace(workspace) do
    slot_file = Path.join(workspace, ".symphony_slot")

    case File.read(slot_file) do
      {:ok, content} ->
        case parse_slot_directory(content) do
          nil ->
            Logger.debug("No DIRECTORY in .symphony_slot, using workspace as-is")
            workspace

          slot_dir when is_binary(slot_dir) ->
            if File.dir?(slot_dir) do
              Logger.info("Using pool slot directory=#{slot_dir} instead of workspace=#{workspace}")
              slot_dir
            else
              Logger.warning("Pool slot directory=#{slot_dir} does not exist, falling back to workspace")
              workspace
            end
        end

      {:error, _} ->
        workspace
    end
  end

  defp parse_slot_directory(content) do
    content
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        ["DIRECTORY", dir] -> String.trim(dir)
        _ -> nil
      end
    end)
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    # Run after_create hook if either:
    # 1. The workspace was just created, or
    # 2. The workspace exists but has no .symphony_slot (slot not claimed yet)
    needs_hook = created? or not File.exists?(Path.join(workspace, ".symphony_slot"))

    case needs_hook do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    env = hook_env(issue_context)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true, env: env)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 4_096) do
    binary_output = IO.iodata_to_binary(output)
    size = byte_size(binary_output)

    case size <= max_bytes do
      true ->
        binary_output

      false ->
        # Show the tail — the actual error is always at the end
        "... (#{size} bytes, showing last #{max_bytes})\n" <>
          binary_part(binary_output, size - max_bytes, max_bytes)
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier, labels: labels, branch_name: branch_name}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: labels || [],
      branch_name: branch_name
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier, labels: labels}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: labels || [],
      branch_name: nil
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: [],
      branch_name: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      labels: [],
      branch_name: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      labels: [],
      branch_name: nil
    }
  end

  defp hook_env(issue_context) do
    labels = Map.get(issue_context, :labels, [])

    env =
      System.get_env()
      |> Map.put("SYMPHONY_ISSUE_ID", issue_context[:issue_id] || "")
      |> Map.put("SYMPHONY_ISSUE_IDENTIFIER", issue_context[:issue_identifier] || "")
      |> Map.put("SYMPHONY_ISSUE_LABELS", Enum.join(labels, ","))
      |> Map.put("SYMPHONY_BRANCH_NAME", issue_context[:branch_name] || "")

    # Routing helper: determine repo from labels
    repo =
      cond do
        Enum.any?(labels, &label_matches_repo?(&1, "2.0")) -> "platform"
        Enum.any?(labels, &label_matches_repo?(&1, "3.0")) -> "procurement"
        true -> ""
      end

    env
    |> Map.put("SYMPHONY_REPO", repo)
    |> Map.put("SYMPHONY_ROOT", Application.app_dir(:symphony_elixir))
    |> Map.put("SYMPHONY_SCRIPTS", scripts_path("") <> "/")
    |> Map.to_list()
  end

  defp label_matches_repo?(label, prefix) do
    normalized = String.downcase(label)
    normalized == prefix or String.starts_with?(normalized, prefix)
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  @doc false
  def scripts_path(script_name) do
    Application.app_dir(:symphony_elixir, Path.join("priv/scripts", script_name))
  end
end
