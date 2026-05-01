defmodule SymphonyElixir.Claude.OneShot do
  @moduledoc """
  Single-turn, no-tools Claude invocations for orchestrator-side reasoning
  (Planner, Grader, Auditor).

  Distinct from `SymphonyElixir.Claude.CLI`, which streams a multi-turn
  agent session with tools enabled. This module shells out to
  `claude -p ...` with `--output-format text` and an empty MCP config,
  captures stdout, and returns a single text or JSON payload.

  Reuses Symphony's existing `Config.claude_command()` so authentication
  and binary resolution are identical to the worker-side invocation.
  """

  require Logger

  alias SymphonyElixir.Config

  @default_timeout_ms 180_000
  @mcp_config_json "{\"mcpServers\":{}}"

  @type opts :: [
          model: String.t(),
          timeout_ms: pos_integer(),
          cwd: Path.t()
        ]

  @doc """
  Send a one-shot prompt to `claude` and return the assistant's text reply.

  The system prompt is delivered via `--append-system-prompt`; `user_prompt`
  is sent via `-p`. Tool use is suppressed by passing an empty MCP config —
  the model still sees built-in tool definitions but the system prompt
  should tell it to reply with text only.
  """
  @spec request(String.t(), String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def request(system_prompt, user_prompt, opts \\ []) when is_binary(system_prompt) and is_binary(user_prompt) do
    {cmd, args} = build_invocation(system_prompt, user_prompt, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    # claude CLI warns "no stdin data received in 3s..." when stdin is open
    # but empty, polluting stdout. Wrap with /bin/sh and redirect stdin from
    # /dev/null so the CLI sees a closed stdin immediately.
    shell_cmd = build_shell_command(cmd, args) <> " < /dev/null"

    task =
      Task.async(fn ->
        System.cmd("/bin/sh", ["-c", shell_cmd], cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, exit_code}} ->
        {:error, {:claude_exit, exit_code, String.slice(output, 0, 2_000)}}

      nil ->
        {:error, {:claude_timeout, timeout_ms}}

      other ->
        {:error, {:claude_unexpected, other}}
    end
  end

  @doc """
  Like `request/3` but parse the assistant's reply as JSON. Strips a
  surrounding ```json ... ``` fence if present, then `Jason.decode`.
  Retries once with a corrective nudge if the first reply isn't valid JSON.
  """
  @spec request_json(String.t(), String.t(), opts()) :: {:ok, map() | list()} | {:error, term()}
  def request_json(system_prompt, user_prompt, opts \\ []) do
    case request(system_prompt, user_prompt, opts) do
      {:ok, text} ->
        case decode_json(text) do
          {:ok, _} = ok ->
            ok

          {:error, _} ->
            Logger.warning("OneShot JSON decode failed; retrying once.")

            retry_user =
              user_prompt <>
                "\n\n[reminder] Reply ONLY with a JSON object — no prose, no code fences."

            with {:ok, retry_text} <- request(system_prompt, retry_user, opts),
                 {:ok, json} <- decode_json(retry_text) do
              {:ok, json}
            end
        end

      err ->
        err
    end
  end

  defp build_invocation(system_prompt, user_prompt, opts) do
    base = [
      "-p",
      user_prompt,
      "--append-system-prompt",
      system_prompt,
      "--output-format",
      "text",
      "--permission-mode",
      "default",
      "--mcp-config",
      @mcp_config_json,
      "--strict-mcp-config"
    ]

    args =
      base
      |> maybe_add_option(Keyword.get(opts, :model) || Config.claude_model(), "--model")

    {cmd, parts} = parse_command(Config.claude_command(), args)
    {cmd, parts}
  end

  defp maybe_add_option(args, nil, _), do: args
  defp maybe_add_option(args, "", _), do: args
  defp maybe_add_option(args, value, flag), do: args ++ [flag, value]

  defp build_shell_command(cmd, args) do
    [cmd | args] |> Enum.map(&shell_escape/1) |> Enum.join(" ")
  end

  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp parse_command(command, extra_args) do
    parts = String.split(command, ~r/\s+/, trim: true)

    {cmd, cmd_args} =
      case parts do
        [cmd | rest] -> {cmd, rest ++ extra_args}
        [] -> {"claude", extra_args}
      end

    resolved_cmd = System.find_executable(cmd) || cmd
    {resolved_cmd, cmd_args}
  end

  defp decode_json(text) do
    trimmed = strip_code_fence(text)

    case Jason.decode(trimmed) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, {:json_decode, text}}
    end
  end

  defp strip_code_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*\n/, "")
    |> String.replace(~r/\n```\s*$/, "")
    |> String.trim()
  end
end
