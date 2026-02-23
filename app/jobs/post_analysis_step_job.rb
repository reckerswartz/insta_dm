require "timeout"

class PostAnalysisStepJob < PostAnalysisPipelineJob
  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:, defer_attempt: 0, **options)
    enqueue_finalizer = true
    raw_result = {}
    completion_payload = {}
    audit_before = nil
    audit_after = nil
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    pipeline_state = context[:pipeline_state]
    if terminal_blocked?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id, options: options) ||
        pipeline_state.step_terminal?(run_id: pipeline_run_id, step: step_key)
      enqueue_finalizer = false
      log_step_event("skipped_terminal", context: context, pipeline_run_id: pipeline_run_id)
      return
    end

    return unless preflight!(context: context, pipeline_run_id: pipeline_run_id, options: options)
    return unless resource_available?(defer_attempt: defer_attempt, context: context, pipeline_run_id: pipeline_run_id, options: options)

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: step_key,
      queue_name: queue_name,
      active_job_id: job_id
    )
    audit_before = post_step_audit_snapshot(context: context)

    raw_result =
      if timeout_seconds
        Timeout.timeout(timeout_seconds) { perform_step!(context: context, pipeline_run_id: pipeline_run_id, options: options) }
      else
        perform_step!(context: context, pipeline_run_id: pipeline_run_id, options: options)
      end

    audit_after = post_step_audit_snapshot(context: context)
    completion_payload = step_completion_result(raw_result: raw_result, context: context, options: options).compact
    record_step_output_audit!(
      context: context,
      pipeline_run_id: pipeline_run_id,
      status: "completed",
      raw_result: raw_result,
      completion_payload: completion_payload,
      audit_before: audit_before,
      audit_after: audit_after,
      defer_attempt: defer_attempt,
      options: options
    )

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step_key,
      status: "succeeded",
      result: completion_payload
    )
  rescue StandardError => e
    if context
      audit_after ||= post_step_audit_snapshot(context: context)
      record_step_output_audit!(
        context: context,
        pipeline_run_id: pipeline_run_id,
        status: "failed",
        raw_result: raw_result,
        completion_payload: completion_payload,
        audit_before: audit_before,
        audit_after: audit_after,
        defer_attempt: defer_attempt,
        options: options,
        error: e
      )
    end

    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step_key,
      status: "failed",
      error: format_error(e),
      result: {
        reason: step_failure_reason
      }
    )

    log_step_error(e: e, context: context, pipeline_run_id: pipeline_run_id)
    raise if retryable_step_error?(e)
  ensure
    if context && enqueue_finalizer
      enqueue_pipeline_finalizer(
        account: context[:account],
        profile: context[:profile],
        post: context[:post],
        pipeline_run_id: pipeline_run_id
      )
    end
  end

  private

  def step_key
    raise NotImplementedError
  end

  def resource_task_name
    step_key
  end

  def max_defer_attempts
    4
  end

  def timeout_seconds
    nil
  end

  def step_failure_reason
    "#{step_key}_analysis_failed"
  end

  def terminal_blocked?(pipeline_state:, pipeline_run_id:, options: {})
    pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
  end

  def preflight!(context:, pipeline_run_id:, options: {})
    true
  end

  def perform_step!(context:, pipeline_run_id:, options: {})
    raise NotImplementedError
  end

  def step_completion_result(raw_result:, context:, options: {})
    raw_result.is_a?(Hash) ? raw_result : {}
  end

  def retryable_step_error?(_error)
    true
  end

  def log_step_event(suffix, context:, pipeline_run_id:)
    Ops::StructuredLogger.info(
      event: "ai.#{step_key}.#{suffix}",
      payload: {
        active_job_id: job_id,
        instagram_account_id: context[:account].id,
        instagram_profile_id: context[:profile].id,
        instagram_profile_post_id: context[:post].id,
        pipeline_run_id: pipeline_run_id
      }
    )
  rescue StandardError
    nil
  end

  def log_step_error(e:, context:, pipeline_run_id:)
    Ops::StructuredLogger.warn(
      event: "ai.#{step_key}.failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: context&.dig(:account)&.id,
        instagram_profile_id: context&.dig(:profile)&.id,
        instagram_profile_post_id: context&.dig(:post)&.id,
        pipeline_run_id: pipeline_run_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 280),
        retryable: retryable_step_error?(e)
      }.compact
    )
  rescue StandardError
    nil
  end

  def resource_available?(defer_attempt:, context:, pipeline_run_id:, options: {})
    guard = Ops::ResourceGuard.allow_ai_task?(task: resource_task_name, queue_name: queue_name, critical: false)
    return true if ActiveModel::Type::Boolean.new.cast(guard[:allow])

    if defer_attempt.to_i >= max_defer_attempts
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: step_key,
        status: "failed",
        error: "resource_guard_exhausted: #{guard[:reason]}",
        result: {
          reason: "resource_constraints",
          snapshot: guard[:snapshot]
        }
      )
      return false
    end

    retry_seconds = guard[:retry_in_seconds].to_i
    retry_seconds = 20 if retry_seconds <= 0

    context[:pipeline_state].mark_step_queued!(
      run_id: pipeline_run_id,
      step: step_key,
      queue_name: queue_name,
      active_job_id: job_id,
      result: {
        reason: "resource_constrained",
        defer_attempt: defer_attempt.to_i,
        retry_in_seconds: retry_seconds,
        snapshot: guard[:snapshot]
      }
    )

    self.class.set(wait: retry_seconds.seconds).perform_later(
      instagram_account_id: context[:account].id,
      instagram_profile_id: context[:profile].id,
      instagram_profile_post_id: context[:post].id,
      pipeline_run_id: pipeline_run_id,
      defer_attempt: defer_attempt.to_i + 1
    )

    false
  end

  def post_step_audit_snapshot(context:)
    post = context[:post]
    post.reload
    Ops::ServiceOutputAuditRecorder.post_persistence_snapshot(post)
  rescue StandardError
    {}
  end

  def audit_service_name
    self.class.name
  end

  def audit_persisted_paths(_raw_result:, _context:, _completion_payload:, _options:)
    []
  end

  def record_step_output_audit!(
    context:,
    pipeline_run_id:,
    status:,
    raw_result:,
    completion_payload:,
    audit_before:,
    audit_after:,
    defer_attempt:,
    options:,
    error: nil
  )
    Ops::ServiceOutputAuditRecorder.record!(
      service_name: audit_service_name,
      execution_source: self.class.name,
      status: status,
      run_id: pipeline_run_id,
      active_job_id: job_id,
      queue_name: queue_name,
      produced: raw_result,
      referenced: completion_payload,
      persisted_before: audit_before,
      persisted_after: audit_after,
      persisted_paths: audit_persisted_paths(
        raw_result: raw_result,
        context: context,
        completion_payload: completion_payload,
        options: options
      ),
      context: context,
      metadata: {
        step_key: step_key,
        defer_attempt: defer_attempt.to_i,
        timeout_seconds: timeout_seconds,
        retryable_error: error.present? ? retryable_step_error?(error) : nil,
        error_class: error&.class&.name,
        error_message: error&.message.to_s&.byteslice(0, 220),
        resource_task_name: resource_task_name.to_s,
        options: options
      }.compact
    )
  rescue StandardError
    nil
  end
end
