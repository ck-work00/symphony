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

  defp release_pool_slot(workspace) do
    slot_file = Path.join(workspace, ".symphony_slot")

    if File.exists?(slot_file) do
      release_script = Path.expand("~/.claude/scripts/symphony-slot-release.sh")

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
  end

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

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
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

  defp issue_context(%{id: issue_id, identifier: identifier, labels: labels}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: labels || []
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: []
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      labels: []
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      labels: []
    }
  end

  defp hook_env(issue_context) do
    labels = Map.get(issue_context, :labels, [])

    env =
      System.get_env()
      |> Map.put("SYMPHONY_ISSUE_ID", issue_context[:issue_id] || "")
      |> Map.put("SYMPHONY_ISSUE_IDENTIFIER", issue_context[:issue_identifier] || "")
      |> Map.put("SYMPHONY_ISSUE_LABELS", Enum.join(labels, ","))

    # Routing helper: determine repo from labels
    repo =
      cond do
        Enum.any?(labels, &label_matches_repo?(&1, "2.0")) -> "platform"
        Enum.any?(labels, &label_matches_repo?(&1, "3.0")) -> "procurement"
        true -> ""
      end

    Map.put(env, "SYMPHONY_REPO", repo)
    |> Map.to_list()
  end

  defp label_matches_repo?(label, prefix) do
    normalized = String.downcase(label)
    normalized == prefix or String.starts_with?(normalized, prefix)
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
