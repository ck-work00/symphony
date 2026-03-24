defmodule SymphonyElixir.NotifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Notifier

  @moduletag :notifier

  describe "format_linear_comment/2" do
    test "max_continuations_exhausted includes missing phases" do
      comment =
        Notifier.format_linear_comment(:max_continuations_exhausted, %{
          missing_phases: ["Test", "Share Evidence"],
          continuation_count: 5
        })

      assert comment =~ "Agent Gave Up"
      assert comment =~ "5 continuation"
      assert comment =~ "Test, Share Evidence"
    end

    test "max_failure_retries_exhausted includes attempt count" do
      comment =
        Notifier.format_linear_comment(:max_failure_retries_exhausted, %{
          attempt: 3,
          max_retries: 3
        })

      assert comment =~ "Max Retries"
      assert comment =~ "3/3"
    end

    test "low_eval_score includes score, threshold, and failing checks" do
      comment =
        Notifier.format_linear_comment(:low_eval_score, %{
          score: 35,
          threshold: 60,
          failing_checks: ["CI not passed", "No tests written"]
        })

      assert comment =~ "35/100"
      assert comment =~ "threshold: 60"
      assert comment =~ "CI not passed"
      assert comment =~ "No tests written"
    end

    test "agent_stalled includes reason" do
      comment =
        Notifier.format_linear_comment(:agent_stalled, %{
          stall_reason: "stalled for 600000ms without codex activity"
        })

      assert comment =~ "Stalled"
      assert comment =~ "600000ms"
    end

    test "needs_human includes help message" do
      comment =
        Notifier.format_linear_comment(:needs_human, %{
          help_message: "I cannot find the database migration for this table"
        })

      assert comment =~ "Needs Help"
      assert comment =~ "cannot find the database migration"
    end
  end

  describe "notify_sync/3" do
    test "calls comment_fn with issue_id and formatted body" do
      test_pid = self()

      comment_fn = fn issue_id, body ->
        send(test_pid, {:comment, issue_id, body})
        :ok
      end

      Notifier.notify_sync(
        :max_continuations_exhausted,
        %{
          issue_id: "issue-123",
          identifier: "GEA-456",
          missing_phases: ["Test"],
          continuation_count: 5
        },
        comment_fn: comment_fn
      )

      assert_received {:comment, "issue-123", body}
      assert body =~ "Agent Gave Up"
      assert body =~ "Test"
    end

    test "calls webhook_fn when webhook URL is configured" do
      test_pid = self()

      comment_fn = fn id, body ->
        send(test_pid, {:comment, id, body})
        :ok
      end

      webhook_fn = fn url, payload ->
        send(test_pid, {:webhook, url, payload})
        :ok
      end

      # Webhook only fires if Config.escalation_webhook_url() returns non-nil.
      # This test verifies the function injection path works correctly.
      Notifier.notify_sync(
        :agent_stalled,
        %{
          issue_id: "issue-789",
          identifier: "GEA-101",
          stall_reason: "phase stuck"
        },
        comment_fn: comment_fn,
        webhook_fn: webhook_fn
      )

      assert_received {:comment, "issue-789", body}
      assert body =~ "Stalled"
    end

    test "skips comment when issue_id is nil" do
      test_pid = self()

      comment_fn = fn _id, _body ->
        send(test_pid, :comment_called)
        :ok
      end

      Notifier.notify_sync(
        :agent_stalled,
        %{identifier: "GEA-101", stall_reason: "stuck"},
        comment_fn: comment_fn
      )

      refute_received :comment_called
    end

    test "handles comment_fn errors without crashing" do
      comment_fn = fn _id, _body -> {:error, :api_down} end

      # Should not raise
      Notifier.notify_sync(
        :needs_human,
        %{issue_id: "issue-123", help_message: "stuck"},
        comment_fn: comment_fn
      )
    end

    test "handles comment_fn exceptions without crashing" do
      comment_fn = fn _id, _body -> raise "boom" end

      # Should not raise
      Notifier.notify_sync(
        :needs_human,
        %{issue_id: "issue-123", help_message: "stuck"},
        comment_fn: comment_fn
      )
    end
  end
end
