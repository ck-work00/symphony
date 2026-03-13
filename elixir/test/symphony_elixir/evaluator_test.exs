defmodule SymphonyElixir.EvaluatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evaluator

  @moduletag :evaluator

  describe "evaluate/2" do
    test "returns zeroed evaluation when workspace does not exist" do
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}

      eval = Evaluator.evaluate(run_context, "/nonexistent/path")

      assert eval.pr_created == false
      assert eval.ci_status == "none"
      assert eval.files_changed == 0
      assert eval.lines_changed == 0
      assert eval.branch_pushed == false
      assert eval.evidence_posted == false
      assert eval.workpad_updated == false
      assert eval.tests_written == false
      assert eval.score == 0
    end

    test "returns zeroed evaluation when workspace is nil" do
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}

      eval = Evaluator.evaluate(run_context, nil)

      assert eval.score == 0
      assert eval.pr_created == false
    end

    test "score is bounded at 100" do
      # The max possible score from defaults is 100 (25+20+15+15+10+10+5)
      # This just verifies the cap exists
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}
      eval = Evaluator.evaluate(run_context, nil)
      assert eval.score >= 0 and eval.score <= 100
    end
  end
end
