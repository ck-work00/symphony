defmodule SymphonyElixir.Evaluator do
  @moduledoc """
  Post-run evaluation: checks what an agent actually accomplished and produces a quality score.

  All checks are fast (shell commands + one Linear API call). Runs synchronously
  after agent process exits, before the retry decision.
  """

  require Logger

  alias SymphonyElixir.History

  @default_weights %{
    pr_created: 25,
    ci_passed: 20,
    tests_written: 15,
    evidence_posted: 15,
    workpad_updated: 10,
    diff_non_empty: 10,
    branch_pushed: 5
  }

  @type evaluation :: %{
          pr_created: boolean(),
          pr_url: String.t() | nil,
          ci_status: String.t(),
          files_changed: integer(),
          lines_changed: integer(),
          branch_pushed: boolean(),
          evidence_posted: boolean(),
          workpad_updated: boolean(),
          tests_written: boolean(),
          score: integer()
        }

  @doc """
  Run all post-completion checks and return a structured evaluation.
  """
  @spec evaluate(map(), String.t() | nil) :: evaluation()
  def evaluate(run_context, workspace_path) do
    issue_id = run_context[:issue_id]
    branch = run_context[:branch_name] || run_context[:identifier]

    pr_result = check_pr(workspace_path, branch)
    ci_status = check_ci(workspace_path, pr_result[:number])
    {files, lines} = check_diff(workspace_path)
    pushed = check_branch_pushed(workspace_path, branch)
    {evidence, workpad} = check_linear_comments(issue_id)
    tests = check_tests_written(workspace_path)

    eval = %{
      pr_created: pr_result[:exists],
      pr_url: pr_result[:url],
      ci_status: ci_status,
      files_changed: files,
      lines_changed: lines,
      branch_pushed: pushed,
      evidence_posted: evidence,
      workpad_updated: workpad,
      tests_written: tests,
      score: 0
    }

    %{eval | score: compute_score(eval)}
  end

  @doc """
  Run evaluation and persist results to the run record.
  """
  @spec evaluate_and_record(String.t(), map(), String.t() | nil) :: {:ok, evaluation()} | {:error, term()}
  def evaluate_and_record(run_id, run_context, workspace_path) do
    eval = evaluate(run_context, workspace_path)

    attrs = %{
      eval_score: eval.score,
      eval_pr_created: eval.pr_created,
      eval_pr_url: eval.pr_url,
      eval_ci_status: eval.ci_status,
      eval_files_changed: eval.files_changed,
      eval_lines_changed: eval.lines_changed,
      eval_branch_pushed: eval.branch_pushed,
      eval_evidence_posted: eval.evidence_posted,
      eval_workpad_updated: eval.workpad_updated,
      eval_tests_written: eval.tests_written
    }

    case History.record_evaluation(run_id, attrs) do
      {:ok, _run} -> {:ok, eval}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Evaluation failed for run #{run_id}: #{Exception.message(error)}")
      {:error, error}
  end

  # ---------------------------------------------------------------------------
  # Individual checks
  # ---------------------------------------------------------------------------

  defp check_pr(workspace_path, branch) do
    case run_in_workspace(workspace_path, "gh pr list --head #{safe_arg(branch)} --json url,number,state --limit 1") do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, [%{"url" => url, "number" => number} | _]} ->
            %{exists: true, url: url, number: number}

          _ ->
            %{exists: false, url: nil, number: nil}
        end

      _ ->
        %{exists: false, url: nil, number: nil}
    end
  end

  defp check_ci(_workspace_path, nil), do: "none"

  defp check_ci(workspace_path, pr_number) do
    case run_in_workspace(workspace_path, "gh pr checks #{pr_number} --json name,state 2>/dev/null") do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, checks} when is_list(checks) ->
            cond do
              Enum.all?(checks, &(&1["state"] == "SUCCESS")) -> "passed"
              Enum.any?(checks, &(&1["state"] == "FAILURE")) -> "failed"
              true -> "pending"
            end

          _ ->
            "none"
        end

      _ ->
        "none"
    end
  end

  defp check_diff(workspace_path) do
    case run_in_workspace(workspace_path, "git diff origin/main --stat 2>/dev/null | tail -1") do
      {:ok, output} ->
        # Parse: " 5 files changed, 120 insertions(+), 30 deletions(-)"
        files =
          case Regex.run(~r/(\d+) files? changed/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        insertions =
          case Regex.run(~r/(\d+) insertions?/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        deletions =
          case Regex.run(~r/(\d+) deletions?/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        {files, insertions + deletions}

      _ ->
        {0, 0}
    end
  end

  defp check_branch_pushed(workspace_path, branch) do
    case run_in_workspace(workspace_path, "git log origin/#{safe_arg(branch)}..HEAD --oneline 2>/dev/null") do
      {:ok, output} ->
        # Empty output means everything is pushed
        String.trim(output) == ""

      _ ->
        false
    end
  end

  defp check_linear_comments(nil), do: {false, false}

  defp check_linear_comments(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        bodies = Enum.map(comments, & &1.body)
        all_text = Enum.join(bodies, "\n")

        evidence = String.contains?(all_text, "![") or String.contains?(all_text, "screenshot")
        workpad = String.contains?(all_text, "## Codex Workpad") or String.contains?(all_text, "## Workpad")

        {evidence, workpad}

      _ ->
        {false, false}
    end
  end

  defp check_tests_written(workspace_path) do
    case run_in_workspace(workspace_path, "git diff origin/main --name-only 2>/dev/null") do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn file ->
          String.contains?(file, "_test.") or
            String.contains?(file, ".test.") or
            String.contains?(file, "/test/") or
            String.contains?(file, "spec.")
        end)

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring
  # ---------------------------------------------------------------------------

  defp compute_score(eval) do
    weights = @default_weights

    score = 0
    score = if eval.pr_created, do: score + weights.pr_created, else: score
    score = if eval.ci_status == "passed", do: score + weights.ci_passed, else: score
    score = if eval.tests_written, do: score + weights.tests_written, else: score
    score = if eval.evidence_posted, do: score + weights.evidence_posted, else: score
    score = if eval.workpad_updated, do: score + weights.workpad_updated, else: score
    score = if eval.files_changed > 0, do: score + weights.diff_non_empty, else: score
    score = if eval.branch_pushed, do: score + weights.branch_pushed, else: score

    min(score, 100)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_in_workspace(nil, _cmd), do: {:error, :no_workspace}

  defp run_in_workspace(workspace_path, cmd) do
    if File.dir?(workspace_path) do
      case System.cmd("sh", ["-c", cmd], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    else
      {:error, :workspace_not_found}
    end
  end

  defp safe_arg(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_\-\/.]/, "")
  end

  defp safe_arg(_), do: ""
end
