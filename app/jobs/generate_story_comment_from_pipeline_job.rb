# frozen_string_literal: true

class GenerateStoryCommentFromPipelineJob < StoryCommentPipelineJob
  include StoryPipelineFailureHandling

  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:llm_comment_generation)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    return if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)

    generation_status = context.dig(:pipeline, "generation", "status").to_s
    unless generation_status == "running"
      acquired = pipeline_state.mark_generation_started!(
        run_id: pipeline_run_id,
        active_job_id: job_id
      )
      return unless acquired
    end

    failed_steps = pipeline_state.failed_steps(run_id: pipeline_run_id)
    failed_required_steps = pipeline_state.failed_required_steps(run_id: pipeline_run_id)
    step_rollup = pipeline_step_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)
    report_stage!(
      event: event,
      stage: "parallel_services",
      state: failed_required_steps.empty? ? "completed" : "completed_with_warnings",
      progress: 40,
      message: failed_required_steps.empty? ? "Parallel analysis jobs completed." : "Parallel analysis jobs completed with warnings.",
      details: {
        pipeline_run_id: pipeline_run_id,
        failed_required_steps: failed_required_steps,
        failed_steps: failed_steps,
        step_rollup: step_rollup
      }
    )
    report_stage!(
      event: event,
      stage: "context_matching",
      state: "running",
      progress: 44,
      message: "Prompt context construction started after parallel jobs completed.",
      details: {
        pipeline_run_id: pipeline_run_id
      }
    )

    generation_result = nil
    payload_result = nil
    payload_audit_before = nil
    payload_audit_after = nil
    generation_audit_before = nil
    generation_audit_after = nil
    audit_context = {
      event: event,
      profile: event.instagram_profile,
      account: event.instagram_profile&.instagram_account
    }
    begin
      with_pipeline_heartbeat(
        event: event,
        pipeline_state: pipeline_state,
        pipeline_run_id: pipeline_run_id,
        step: "llm_generation",
        interval_seconds: 20,
        progress: 68,
        # Local model inference can be slow under CPU/GPU pressure; heartbeats make
        # prolonged processing explicit so operators can distinguish progress vs. failure.
        message: "LLM is still processing on local resources; large-model inference may take several minutes."
      ) do
        payload_audit_before = Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event)
        payload = LlmComment::StoryIntelligencePayloadResolver.new(
          event: event,
          pipeline_state: pipeline_state,
          pipeline_run_id: pipeline_run_id,
          active_job_id: job_id
        ).fetch!
        payload_result = payload

        event.persist_local_story_intelligence!(payload)
        payload_audit_after = Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload)
        record_story_service_output_audit!(
          service_name: LlmComment::StoryIntelligencePayloadResolver.name,
          status: "completed",
          produced: payload_result,
          referenced: {
            source: payload_result[:source],
            reason: payload_result[:reason],
            transcript_present: payload_result[:transcript].to_s.present?,
            topics_count: Array(payload_result[:topics]).length
          },
          persisted_before: payload_audit_before,
          persisted_after: payload_audit_after,
          context: audit_context,
          pipeline_run_id: pipeline_run_id,
          metadata: {
            step: "context_matching",
            active_job_id: job_id
          }
        )
        report_stage!(
          event: event,
          stage: "context_matching",
          state: "completed",
          progress: 46,
          message: "Context matching completed.",
          details: {
            pipeline_run_id: pipeline_run_id,
            source: payload[:source].to_s.presence
          }
        )

        generation_audit_before = Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload)
        generation_result = LlmComment::EventGenerationPipeline.new(
          event: event,
          provider: provider,
          model: model,
          skip_media_stage_reporting: true
        ).call
        generation_audit_after = Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload)
        record_story_service_output_audit!(
          service_name: LlmComment::EventGenerationPipeline.name,
          status: "completed",
          produced: generation_result,
          referenced: {
            selected_comment: generation_result[:selected_comment].to_s.presence,
            relevance_score: generation_result[:relevance_score],
            ranked_candidates_count: Array(generation_result[:ranked_candidates]).length
          },
          persisted_before: generation_audit_before,
          persisted_after: generation_audit_after,
          context: audit_context,
          pipeline_run_id: pipeline_run_id,
          metadata: {
            step: "llm_generation",
            provider: provider,
            model: model,
            active_job_id: job_id
          }
        )
      end
    rescue InstagramProfileEvent::LocalStoryIntelligence::LocalStoryIntelligenceUnavailableError => e
      record_story_service_output_audit!(
        service_name: LlmComment::StoryIntelligencePayloadResolver.name,
        status: "failed",
        produced: payload_result,
        referenced: {},
        persisted_before: payload_audit_before || Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event),
        persisted_after: Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload),
        context: audit_context,
        pipeline_run_id: pipeline_run_id,
        metadata: {
          step: "context_matching",
          active_job_id: job_id,
          error_class: e.class.name,
          error_message: e.message.to_s.byteslice(0, 220),
          reason: e.reason.to_s.presence,
          source: e.source.to_s.presence
        }.compact
      )
      mark_story_pipeline_skipped!(
        event: event,
        pipeline_state: pipeline_state,
        pipeline_run_id: pipeline_run_id,
        error: e,
        active_job_id: job_id
      )
      return
    end

    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: "completed",
      details: {
        completed_by: self.class.name,
        active_job_id: job_id,
        completed_at: Time.current.iso8601(3),
        failed_steps: failed_steps,
        step_rollup: step_rollup
      }
    )
    enqueue_deferred_steps(
      event: event,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id,
      provider: provider,
      model: model,
      requested_by: requested_by
    )
    timing_rollup = pipeline_timing_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)

    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        failed_required_steps: failed_required_steps,
        failed_steps: failed_steps,
        step_rollup: step_rollup,
        selected_comment: generation_result[:selected_comment].to_s.byteslice(0, 180),
        relevance_score: generation_result[:relevance_score]
      }.merge(timing_rollup)
    )
  rescue StandardError => e
    if context
      event = context[:event]
      audit_context = {
        event: event,
        profile: event.instagram_profile,
        account: event.instagram_profile&.instagram_account
      }
      if generation_result.present? || generation_audit_before.present?
        record_story_service_output_audit!(
          service_name: LlmComment::EventGenerationPipeline.name,
          status: "failed",
          produced: generation_result,
          referenced: {},
          persisted_before: generation_audit_before || Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event),
          persisted_after: generation_audit_after || Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload),
          context: audit_context,
          pipeline_run_id: pipeline_run_id,
          metadata: {
            step: "llm_generation",
            provider: provider,
            model: model,
            active_job_id: job_id,
            error_class: e.class.name,
            error_message: e.message.to_s.byteslice(0, 220)
          }
        )
      elsif payload_result.present? || payload_audit_before.present?
        record_story_service_output_audit!(
          service_name: LlmComment::StoryIntelligencePayloadResolver.name,
          status: "failed",
          produced: payload_result,
          referenced: {},
          persisted_before: payload_audit_before || Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event),
          persisted_after: payload_audit_after || Ops::ServiceOutputAuditRecorder.event_persistence_snapshot(event.reload),
          context: audit_context,
          pipeline_run_id: pipeline_run_id,
          metadata: {
            step: "context_matching",
            active_job_id: job_id,
            error_class: e.class.name,
            error_message: e.message.to_s.byteslice(0, 220)
          }
        )
      end
    end

    if context
      fail_story_pipeline!(
        event: context[:event],
        pipeline_state: context[:pipeline_state],
        pipeline_run_id: pipeline_run_id,
        error: truncated_error(e),
        active_job_id: job_id
      )
    end

    Ops::StructuredLogger.error(
      event: "llm_comment.pipeline.failed",
      payload: {
        event_id: context&.dig(:event)&.id || instagram_profile_event_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? { step_rollup: pipeline_step_rollup(pipeline_state: context[:pipeline_state], run_id: pipeline_run_id) } : {}
      ).merge(
        context ? pipeline_timing_rollup(pipeline_state: context[:pipeline_state], run_id: pipeline_run_id) : {}
      )
    )
    raise
  end

  private

  def record_story_service_output_audit!(
    service_name:,
    status:,
    produced:,
    referenced:,
    persisted_before:,
    persisted_after:,
    context:,
    pipeline_run_id:,
    metadata: {}
  )
    Ops::ServiceOutputAuditRecorder.record!(
      service_name: service_name.to_s,
      execution_source: self.class.name,
      status: status,
      run_id: pipeline_run_id,
      active_job_id: job_id,
      queue_name: queue_name,
      produced: produced,
      referenced: referenced,
      persisted_before: persisted_before,
      persisted_after: persisted_after,
      context: context,
      metadata: metadata
    )
  rescue StandardError
    nil
  end

  def mark_story_pipeline_skipped!(event:, pipeline_state:, pipeline_run_id:, error:, active_job_id: nil)
    step_rollup = pipeline_step_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)

    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: "completed",
      details: {
        completed_by: self.class.name,
        active_job_id: active_job_id.to_s.presence || job_id,
        completed_at: Time.current.iso8601(3),
        skipped: true,
        skip_reason: error.reason.to_s.presence || "local_story_intelligence_unavailable",
        skip_source: error.source.to_s.presence,
        skip_message: error.message.to_s,
        step_rollup: step_rollup
      }.compact
    )
    timing_rollup = pipeline_timing_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)

    event.mark_llm_comment_skipped!(
      message: error.message.to_s,
      reason: error.reason,
      source: error.source
    )

    report_stage!(
      event: event,
      stage: "llm_generation",
      state: "completed_with_warnings",
      progress: 100,
      message: "Comment generation skipped due to unavailable story intelligence.",
      details: {
        pipeline_run_id: pipeline_run_id,
        reason: error.reason.to_s.presence || "local_story_intelligence_unavailable",
        source: error.source.to_s.presence,
        step_rollup: step_rollup
      }.merge(timing_rollup)
    )

    Ops::StructuredLogger.warn(
      event: "llm_comment.pipeline.skipped",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: active_job_id.to_s.presence || job_id,
        provider: provider,
        model: model,
        reason: error.reason.to_s.presence || "local_story_intelligence_unavailable",
        source: error.source.to_s.presence,
        message: error.message.to_s
      }.merge(timing_rollup)
    )
  rescue StandardError
    nil
  end

  def enqueue_deferred_steps(event:, pipeline_state:, pipeline_run_id:, provider:, model:, requested_by:)
    pending_steps = pipeline_state.steps_requiring_execution(run_id: pipeline_run_id)
    deferred_steps = pipeline_state.deferred_steps(run_id: pipeline_run_id)
    steps = pending_steps.select { |step| deferred_steps.include?(step) }
    return if steps.empty?

    stage_job_map = LlmComment::StepRegistry.stage_job_map
    steps.each do |step|
      job_class = stage_job_map[step]
      next unless job_class

      job = job_class.perform_later(
        instagram_profile_event_id: event.id,
        pipeline_run_id: pipeline_run_id,
        provider: provider,
        model: model,
        requested_by: requested_by
      )

      pipeline_state.mark_step_queued!(
        run_id: pipeline_run_id,
        step: step,
        queue_name: job.queue_name,
        active_job_id: job.job_id,
        result: {
          enqueued_by: self.class.name,
          deferred: true,
          enqueued_at: Time.current.iso8601(3)
        }
      )

      report_stage!(
        event: event,
        stage: step,
        state: "queued",
        progress: step_progress(step, :queued),
        message: "Deferred enrichment queued.",
        details: {
          pipeline_run_id: pipeline_run_id,
          active_job_id: job.job_id,
          queue_name: job.queue_name,
          deferred: true
        }
      )
      Ops::StructuredLogger.info(
        event: "llm_comment.pipeline.deferred_step_queued",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          pipeline_run_id: pipeline_run_id,
          step: step,
          active_job_id: job_id,
          deferred_job_id: job.job_id,
          deferred_queue_name: job.queue_name
        }
      )
    rescue StandardError => e
      pipeline_state.mark_step_completed!(
        run_id: pipeline_run_id,
        step: step,
        status: "failed",
        error: "deferred_enqueue_failed: #{e.class}: #{e.message}".byteslice(0, 320),
        result: {
          reason: "deferred_enqueue_failed"
        }
      )
      report_stage!(
        event: event,
        stage: step,
        state: "failed",
        progress: step_progress(step, :failed),
        message: "Deferred enrichment enqueue failed.",
        details: {
          pipeline_run_id: pipeline_run_id,
          error_class: e.class.name,
          error_message: e.message.to_s.byteslice(0, 220),
          deferred: true
        }
      )
    end
  rescue StandardError
    nil
  end
end
