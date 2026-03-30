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
          plan_posted: boolean(),
          simplify_done: boolean(),
          score: integer()
        }

  @doc """
  Run all post-completion checks and return a structured evaluation.
  """
  @spec evaluate(map(), String.t() | nil) :: evaluation()
  def evaluate(run_context, workspace_path) do
    issue_id = run_context[:issue_id]
    branch = run_context[:branch_name] || run_context[:identifier]

    # Resolve actual working directory from pool slot if present
    workspace_path = resolve_workspace_path(workspace_path)

    # Try the actual git branch first, then fall back to Linear branch name and identifier
    pr_result =
      case detect_current_branch(workspace_path) do
        {:ok, current} -> check_pr(workspace_path, current)
        _ -> check_pr(workspace_path, branch)
      end

    pr_result =
      if !pr_result[:exists] and branch != run_context[:identifier] do
        check_pr(workspace_path, run_context[:identifier])
      else
        pr_result
      end

    ci_status = check_ci(workspace_path, pr_result[:number])
    {files, lines} = check_diff(workspace_path)
    pushed = check_branch_pushed(workspace_path, branch)
    {evidence, workpad} = check_linear_comments(issue_id)
    tests = check_tests_written(workspace_path)
    plan = check_plan_posted(issue_id)
    simplify = check_simplify_done(workspace_path, issue_id)

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
      plan_posted: plan,
      simplify_done: simplify,
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

  @doc """
  Returns a list of human-readable descriptions of failing checks from an evaluation.
  """
  @spec failing_checks(evaluation()) :: [String.t()]
  def failing_checks(eval) do
    checks = [
      {eval.pr_created, "PR not created"},
      {eval.ci_status == "passed", "CI not passed"},
      {eval.tests_written, "No tests written"},
      {eval.evidence_posted, "No evidence posted"},
      {eval.workpad_updated, "Workpad not updated"},
      {eval.files_changed > 0, "No code changes"},
      {eval.branch_pushed, "Branch not pushed"}
    ]

    for {passing, label} <- checks, !passing, do: label
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
        files = String.split(output, "\n", trim: true)

        test_files = Enum.filter(files, &test_file?/1)
        source_files = Enum.reject(files, &test_file?/1)

        has_tests = length(test_files) > 0

        if has_tests and length(source_files) > 0 do
          Logger.info("Evaluator: test coverage — #{length(test_files)} test files for #{length(source_files)} source files")
        end

        has_tests

      _ ->
        false
    end
  end

  defp test_file?(file) do
    String.contains?(file, "_test.") or
      String.contains?(file, ".test.") or
      String.contains?(file, "/test/") or
      String.contains?(file, "spec.")
  end

  defp check_plan_posted(nil), do: false

  defp check_plan_posted(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        all_text = comments |> Enum.map(& &1.body) |> Enum.join("\n")

        String.contains?(all_text, "## Requirements") or
          String.contains?(all_text, "- [ ]") or
          String.contains?(all_text, "## Implementation") or
          String.contains?(all_text, "### Plan")

      _ ->
        false
    end
  end

  defp check_simplify_done(_workspace_path, nil), do: false

  defp check_simplify_done(workspace_path, issue_id) do
    simplify_commit =
      case run_in_workspace(workspace_path, "git log --oneline --grep='simplify' origin/main..HEAD 2>/dev/null") do
        {:ok, output} -> String.trim(output) != ""
        _ -> false
      end

    no_changes_comment =
      case SymphonyElixir.Linear.Client.fetch_issue_comments(issue_id) do
        {:ok, comments} ->
          Enum.any?(comments, fn c ->
            String.contains?(String.downcase(c.body), "no simplification needed") or
              String.contains?(String.downcase(c.body), "no changes needed")
          end)

        _ ->
          false
      end

    simplify_commit or no_changes_comment
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

  defp detect_current_branch(nil), do: {:error, :no_workspace}

  defp detect_current_branch(workspace_path) do
    case run_in_workspace(workspace_path, "git branch --show-current 2>/dev/null") do
      {:ok, output} ->
        branch = String.trim(output)
        if branch != "", do: {:ok, branch}, else: {:error, :no_branch}

      _ ->
        {:error, :no_branch}
    end
  end

  # Resolve the actual working directory. Pool-based workspaces contain a
  # `.symphony_slot` file that points to the real git repo directory.
  defp resolve_workspace_path(nil), do: nil

  defp resolve_workspace_path(path) do
    slot_file = Path.join(path, ".symphony_slot")

    if File.exists?(slot_file) do
      case File.read(slot_file) do
        {:ok, content} ->
          case Regex.run(~r/DIRECTORY=(.+)/, content) do
            [_, dir] ->
              resolved = String.trim(dir)

              if File.dir?(resolved) do
                Logger.info("Evaluator: resolved workspace #{path} -> #{resolved}")
                resolved
              else
                path
              end

            _ ->
              path
          end

        _ ->
          path
      end
    else
      path
    end
  end
end
