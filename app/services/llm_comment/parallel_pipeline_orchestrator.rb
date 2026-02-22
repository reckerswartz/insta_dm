# frozen_string_literal: true

module LlmComment
  class ParallelPipelineOrchestrator
    STAGE_JOB_MAP = LlmComment::StepRegistry.stage_job_map.freeze

    def initialize(event:, provider:, model:, requested_by:, source_job_id:, regenerate_all: false)
      @event = event
      @provider = provider.to_s
      @model = model
      @requested_by = requested_by.to_s
      @source_job_id = source_job_id.to_s
      @regenerate_all = ActiveModel::Type::Boolean.new.cast(regenerate_all)
    end

    def call
      pipeline_state = ParallelPipelineState.new(event: event)
      start_result = pipeline_state.start!(
        provider: provider,
        model: model,
        requested_by: requested_by,
        source_job: self.class.name,
        active_job_id: source_job_id,
        regenerate_all: regenerate_all
      )
      run_id = start_result[:run_id].to_s
      return reused_result(run_id: run_id) unless start_result[:started]

      steps_to_enqueue = pipeline_state.required_steps_requiring_execution(run_id: run_id)
      enqueued_steps = enqueue_stage_jobs(
        pipeline_state: pipeline_state,
        run_id: run_id,
        steps: steps_to_enqueue
      )
      reused_steps = ParallelPipelineState::STEP_KEYS - steps_to_enqueue
      finalizer = enqueue_finalizer(run_id: run_id)

      Ops::StructuredLogger.info(
        event: "llm_comment.parallel_pipeline.started",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          pipeline_run_id: run_id,
          provider: provider,
          model: model,
          requested_by: requested_by,
          regenerate_all: regenerate_all,
          resume_mode: start_result[:resume_mode],
          resumed_from_run_id: start_result[:resumed_from_run_id],
          source_active_job_id: source_job_id,
          stage_jobs_required: pipeline_state.required_steps(run_id: run_id),
          stage_jobs_deferred: pipeline_state.deferred_steps(run_id: run_id),
          stage_jobs_requested: steps_to_enqueue,
          stage_jobs_reused: reused_steps,
          stage_jobs: enqueued_steps,
          finalizer_job_id: finalizer&.job_id,
          finalizer_queue_name: finalizer&.queue_name
        }.compact
      )

      {
        status: "pipeline_enqueued",
        run_id: run_id,
        resume_mode: start_result[:resume_mode],
        resumed_from_run_id: start_result[:resumed_from_run_id],
        stage_jobs_required: pipeline_state.required_steps(run_id: run_id),
        stage_jobs_deferred: pipeline_state.deferred_steps(run_id: run_id),
        stage_jobs_requested: steps_to_enqueue,
        stage_jobs_reused: reused_steps,
        stage_jobs: enqueued_steps,
        finalizer_job_id: finalizer&.job_id
      }
    end

    private

    attr_reader :event, :provider, :model, :requested_by, :source_job_id, :regenerate_all

    def enqueue_stage_jobs(pipeline_state:, run_id:, steps:)
      Array(steps).map(&:to_s).each_with_object({}) do |stage, out|
        job_class = STAGE_JOB_MAP[stage]
        next unless job_class

        job = job_class.perform_later(
          instagram_profile_event_id: event.id,
          pipeline_run_id: run_id,
          provider: provider,
          model: model,
          requested_by: requested_by
        )

        pipeline_state.mark_step_queued!(
          run_id: run_id,
          step: stage,
          queue_name: job.queue_name,
          active_job_id: job.job_id,
          result: {
            enqueued_by: self.class.name,
            enqueued_at: Time.current.iso8601(3)
          }
        )

        event.record_llm_processing_stage!(
          stage: stage,
          state: "queued",
          progress: queued_progress_for(stage),
          message: "#{human_stage(stage)} queued in #{job.queue_name}.",
          details: {
            pipeline_run_id: run_id,
            active_job_id: job.job_id,
            queue_name: job.queue_name
          }
        )

        out[stage] = {
          job_id: job.job_id,
          queue_name: job.queue_name
        }
      rescue StandardError => e
        pipeline_state.mark_step_completed!(
          run_id: run_id,
          step: stage,
          status: "failed",
          error: "enqueue_failed: #{e.class}: #{e.message}".byteslice(0, 320),
          result: {
            reason: "enqueue_failed"
          }
        )

        event.record_llm_processing_stage!(
          stage: stage,
          state: "failed",
          progress: queued_progress_for(stage),
          message: "#{human_stage(stage)} enqueue failed.",
          details: {
            pipeline_run_id: run_id,
            error_class: e.class.name,
            error_message: e.message.to_s.byteslice(0, 200)
          }
        )

        out[stage] = {
          error_class: e.class.name,
          error_message: e.message.to_s.byteslice(0, 200)
        }
      end
    end

    def enqueue_finalizer(run_id:)
      FinalizeStoryCommentPipelineJob.perform_later(
        instagram_profile_event_id: event.id,
        pipeline_run_id: run_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        attempts: 0
      )
    rescue StandardError
      nil
    end

    def reused_result(run_id:)
      {
        status: "pipeline_already_running",
        run_id: run_id
      }
    end

    def queued_progress_for(stage)
      LlmComment::StepRegistry.progress_for(step: stage, state: :queued)
    end

    def human_stage(stage)
      stage.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end
  end
end
