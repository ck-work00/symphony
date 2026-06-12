defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, History, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        completed = Map.get(snapshot, :completed_history, [])
        # An issue's open PR shown on every row for it (running or completed),
        # even on a run that didn't itself detect the URL: DB-recorded PRs per
        # issue, overlaid with any freshly-detected PRs in this live snapshot.
        pr_by_issue =
          History.pr_urls_by_issue()
          |> Map.merge(detected_pr_urls(snapshot.running ++ completed))

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload(&1, pr_by_issue)),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          completed_history: Enum.map(completed, &completed_entry_payload(&1, pr_by_issue)),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry, pr_by_issue) do
    slot = read_slot_info(entry.identifier)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      phase: Map.get(entry, :phase),
      phases_seen: Map.get(entry, :phases_seen, []),
      pr_url: Map.get(entry, :pr_url) || Map.get(pr_by_issue, entry.identifier),
      screenshot_urls: Map.get(entry, :screenshot_urls, []),
      history_run_id: Map.get(entry, :history_run_id),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      frontend_url: slot[:frontend_url],
      backend_url: slot[:backend_url],
      tokens: %{
        input_tokens: Map.get(entry, :cumulative_input_tokens, entry.codex_input_tokens),
        output_tokens: Map.get(entry, :cumulative_output_tokens, entry.codex_output_tokens),
        total_tokens: Map.get(entry, :cumulative_total_tokens, entry.codex_total_tokens)
      }
    }
  end

  defp read_slot_info(identifier) when is_binary(identifier) do
    workspace = Path.join(Config.workspace_root(), identifier)
    slot_file = Path.join(workspace, ".symphony_slot")

    case File.read(slot_file) do
      {:ok, content} ->
        frontend_port = extract_slot_value(content, "FRONTEND_PORT")
        phoenix_port = extract_slot_value(content, "PHOENIX_PORT")

        %{
          frontend_url: if(frontend_port, do: "http://localhost:#{frontend_port}"),
          backend_url: if(phoenix_port, do: "http://localhost:#{phoenix_port}")
        }

      _ ->
        %{frontend_url: nil, backend_url: nil}
    end
  end

  defp read_slot_info(_), do: %{frontend_url: nil, backend_url: nil}

  defp extract_slot_value(content, key) do
    case Regex.run(~r/#{key}=(\d+)/, content) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp completed_entry_payload(entry, pr_by_issue) when is_map(entry) do
    entry
    |> Map.update(:last_message, nil, fn
      nil -> nil
      msg when is_binary(msg) -> msg
      msg -> summarize_message(msg)
    end)
    # Show the issue's PR even on a no-op re-dispatch row that didn't detect one:
    # a finished run that opened a PR earlier still has an open PR for the issue.
    |> Map.update(:pr_url, nil, fn
      nil -> Map.get(pr_by_issue, Map.get(entry, :issue_identifier))
      url -> url
    end)
  end

  # PR URLs freshly detected in this snapshot, keyed by issue identifier. Handles
  # both entry shapes: running entries key the identifier as :identifier,
  # completed-history entries as :issue_identifier.
  defp detected_pr_urls(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      identifier = Map.get(entry, :issue_identifier) || Map.get(entry, :identifier)
      pr_url = Map.get(entry, :pr_url)

      if is_binary(identifier) and is_binary(pr_url) and not Map.has_key?(acc, identifier) do
        Map.put(acc, identifier, pr_url)
      else
        acc
      end
    end)
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      phase: Map.get(running, :phase),
      pr_url: Map.get(running, :pr_url),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: Map.get(running, :cumulative_input_tokens, running.codex_input_tokens),
        output_tokens: Map.get(running, :cumulative_output_tokens, running.codex_output_tokens),
        total_tokens: Map.get(running, :cumulative_total_tokens, running.codex_total_tokens)
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
