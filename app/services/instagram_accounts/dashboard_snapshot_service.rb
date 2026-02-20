module InstagramAccounts
  class DashboardSnapshotService
    DEFAULT_FAILURE_LIMIT = 25
    DEFAULT_AUDIT_LIMIT = 120
    DEFAULT_ACTION_LIMIT = 20
    DEFAULT_SKIP_WINDOW_HOURS = 72

    def initialize(
      account:,
      failure_limit: DEFAULT_FAILURE_LIMIT,
      audit_limit: DEFAULT_AUDIT_LIMIT,
      action_limit: DEFAULT_ACTION_LIMIT,
      skip_window_hours: DEFAULT_SKIP_WINDOW_HOURS
    )
      @account = account
      @failure_limit = failure_limit.to_i.clamp(1, 200)
      @audit_limit = audit_limit.to_i.clamp(1, 500)
      @action_limit = action_limit.to_i.clamp(1, 120)
      @skip_window_hours = skip_window_hours.to_i.clamp(1, 168)
    end

    def call
      {
        issues: Ops::AccountIssues.for(account),
        metrics: Ops::Metrics.for_account(account),
        latest_sync_run: account.sync_runs.order(created_at: :desc).first,
        recent_failures: recent_failures,
        recent_audit_entries: Ops::AuditLogBuilder.for_account(instagram_account: account, limit: audit_limit),
        actions_todo_queue: actions_todo_queue_summary,
        skip_diagnostics: skip_diagnostics
      }
    end

    private

    attr_reader :account, :failure_limit, :audit_limit, :action_limit, :skip_window_hours

    def recent_failures
      BackgroundJobFailure
        .where(instagram_account_id: account.id)
        .order(occurred_at: :desc, id: :desc)
        .limit(failure_limit)
    end

    def actions_todo_queue_summary
      Workspace::ActionsTodoQueueService.new(
        account: account,
        limit: action_limit,
        enqueue_processing: true
      ).fetch!
    rescue StandardError => e
      {
        items: [],
        stats: {
          total_items: 0,
          ready_items: 0,
          processing_items: 0,
          enqueued_now: 0,
          refreshed_at: Time.current.iso8601(3),
          error: e.message.to_s
        }
      }
    end

    def skip_diagnostics
      SkipDiagnosticsService.new(account: account, hours: skip_window_hours).call
    end
  end
end
