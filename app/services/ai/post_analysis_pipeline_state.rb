require "securerandom"

module Ai
  class PostAnalysisPipelineState
    STEP_KEYS = %w[visual face ocr video metadata].freeze
    TERMINAL_STATUSES = %w[succeeded failed skipped].freeze
    PIPELINE_TERMINAL_STATUSES = %w[completed failed].freeze
    STEP_TO_QUEUE_SERVICE_KEY = {
      "visual" => :visual_analysis,
      "face" => :face_analysis,
      "ocr" => :ocr_analysis,
      "video" => :video_analysis,
      "metadata" => :metadata_tagging
    }.freeze
    DEFAULT_PENDING_ESTIMATE_SECONDS = ENV.fetch("POST_PIPELINE_DEFAULT_PENDING_ESTIMATE_SECONDS", "180").to_i.clamp(20, 7_200)

    DEFAULT_TASK_FLAGS = {
      "analyze_visual" => true,
      "analyze_faces" => false,
      "secondary_face_analysis" => true,
      "secondary_only_on_ambiguous" => true,
      "run_ocr" => false,
      "run_video" => true,
      "run_metadata" => true,
      "generate_comments" => true,
      "enforce_comment_evidence_policy" => true,
      "retry_on_incomplete_profile" => true
    }.freeze

    TASK_TO_STEP = {
      "analyze_visual" => "visual",
      "analyze_faces" => "face",
      "run_ocr" => "ocr",
      "run_video" => "video",
      "run_metadata" => "metadata"
    }.freeze

    def initialize(post:)
      @post = post
    end

    attr_reader :post

    def start!(task_flags: {}, source_job: nil, run_id: SecureRandom.uuid)
      normalized_flags = normalize_task_flags(task_flags)
      required_steps = required_steps_for(flags: normalized_flags)
      now = iso_timestamp

      post.with_lock do
        post.reload
        metadata = metadata_for(post)
        metadata.delete("ai_pipeline_failure")
        metadata["ai_pipeline"] = {
          "run_id" => run_id,
          "status" => "running",
          "source_job" => source_job.to_s.presence,
          "created_at" => now,
          "updated_at" => now,
          "task_flags" => normalized_flags,
          "required_steps" => required_steps,
          "steps" => build_initial_steps(required_steps: required_steps, at: now)
        }.compact

        pipeline = metadata["ai_pipeline"]
        post.update!(
          ai_status: "running",
          analyzed_at: nil,
          metadata: metadata,
          **pending_projection_for(
            pipeline: pipeline,
            existing_pending_since_at: Time.current,
            existing_next_retry_at: nil,
            existing_estimated_ready_at: nil,
            existing_blocking_step: nil
          )
        )
      end

      run_id
    end

    def pipeline_for(run_id:)
      pipeline = current_pipeline
      return nil unless pipeline.is_a?(Hash)
      return nil unless pipeline["run_id"].to_s == run_id.to_s

      pipeline
    end

    def current_pipeline
      metadata_for(post)["ai_pipeline"]
    end

    def required_steps(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return [] unless pipeline.is_a?(Hash)

      Array(pipeline["required_steps"]).map(&:to_s)
    end

    def step_state(run_id:, step:)
      pipeline = pipeline_for(run_id: run_id)
      return nil unless pipeline.is_a?(Hash)

      pipeline.dig("steps", step.to_s)
    end

    def step_terminal?(run_id:, step:)
      TERMINAL_STATUSES.include?(step_state(run_id: run_id, step: step).to_h["status"].to_s)
    end

    def pipeline_terminal?(run_id:)
      PIPELINE_TERMINAL_STATUSES.include?(pipeline_for(run_id: run_id).to_h["status"].to_s)
    end

    def mark_step_running!(run_id:, step:, queue_name:, active_job_id:)
      mark_step!(
        run_id: run_id,
        step: step,
        status: "running",
        queue_name: queue_name,
        active_job_id: active_job_id,
        started_at: iso_timestamp
      )
    end

    def mark_step_queued!(run_id:, step:, queue_name:, active_job_id:, result: nil)
      mark_step!(
        run_id: run_id,
        step: step,
        status: "queued",
        queue_name: queue_name,
        active_job_id: active_job_id,
        result: result,
        started_at: nil
      )
    end

    def mark_step_completed!(run_id:, step:, status:, result: nil, error: nil)
      normalized_status = status.to_s
      normalized_status = "failed" unless (TERMINAL_STATUSES + [ "queued", "running", "pending" ]).include?(normalized_status)

      mark_step!(
        run_id: run_id,
        step: step,
        status: normalized_status,
        result: result,
        error: error,
        finished_at: iso_timestamp
      )
    end

    def all_required_steps_terminal?(run_id:)
      required = required_steps(run_id: run_id)
      return false if required.empty?

      required.all? do |step|
        TERMINAL_STATUSES.include?(step_state(run_id: run_id, step: step).to_h["status"].to_s)
      end
    end

    def core_steps_terminal?(run_id:)
      required = required_steps(run_id: run_id)
      core = required - [ "metadata" ]
      return true if core.empty?

      core.all? do |step|
        TERMINAL_STATUSES.include?(step_state(run_id: run_id, step: step).to_h["status"].to_s)
      end
    end

    def core_steps_succeeded?(run_id:)
      required = required_steps(run_id: run_id)
      core = required - [ "metadata" ]
      return true if core.empty?

      core.all? do |step|
        step_state(run_id: run_id, step: step).to_h["status"].to_s == "succeeded"
      end
    end

    def failed_required_steps(run_id:, include_metadata: true)
      required = required_steps(run_id: run_id)
      required = required - [ "metadata" ] unless include_metadata
      required.select do |step|
        step_state(run_id: run_id, step: step).to_h["status"].to_s == "failed"
      end
    end

    def mark_pipeline_finished!(run_id:, status:, details: nil)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        pipeline["status"] = status.to_s
        pipeline["updated_at"] = iso_timestamp
        pipeline["finished_at"] = iso_timestamp
        pipeline["details"] = details if details.present?
      end
    end

    def required_step_pending?(run_id:, step:)
      required = required_steps(run_id: run_id)
      return false unless required.include?(step.to_s)

      step_row = step_state(run_id: run_id, step: step).to_h
      step_row["status"].to_s.in?([ "", "pending" ])
    end

    private

    def mark_step!(run_id:, step:, status:, queue_name: nil, active_job_id: nil, result: nil, error: nil, started_at: nil, finished_at: nil)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        key = step.to_s
        steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
        row = steps[key].is_a?(Hash) ? steps[key] : {}

        # Count attempts only when a worker actually starts execution.
        attempts = row["attempts"].to_i
        attempts += 1 if status.to_s == "running"

        row["status"] = status.to_s
        row["queue_name"] = queue_name if queue_name.present?
        row["active_job_id"] = active_job_id if active_job_id.present?
        row["started_at"] = started_at if started_at.present?
        row["finished_at"] = finished_at if finished_at.present?
        row["attempts"] = attempts
        row["result"] = result if result.is_a?(Hash)
        if error.present?
          row["error"] = error.to_s
        elsif status.to_s.in?(%w[succeeded skipped pending queued running])
          row["error"] = nil
        end

        steps[key] = row
        pipeline["steps"] = steps
        pipeline["updated_at"] = iso_timestamp
      end
    end

    def with_pipeline_update(run_id:)
      post.with_lock do
        post.reload
        metadata = metadata_for(post)
        pipeline = metadata["ai_pipeline"]
        return nil unless pipeline.is_a?(Hash)
        return nil unless pipeline["run_id"].to_s == run_id.to_s

        yield(pipeline, metadata)

        metadata["ai_pipeline"] = pipeline
        post.update!(
          metadata: metadata,
          **pending_projection_for(
            pipeline: pipeline,
            existing_pending_since_at: post.ai_pending_since_at,
            existing_next_retry_at: post.ai_next_retry_at,
            existing_estimated_ready_at: post.ai_estimated_ready_at,
            existing_blocking_step: post.ai_blocking_step
          )
        )
        pipeline
      end
    end

    def pending_projection_for(pipeline:, existing_pending_since_at:, existing_next_retry_at:, existing_estimated_ready_at:, existing_blocking_step:)
      return terminal_pending_projection(pipeline: pipeline) unless pipeline.to_h["status"].to_s == "running"

      blocking_step = blocking_step_for(pipeline: pipeline)
      created_at = parse_time(pipeline["created_at"])
      pending_since_at = existing_pending_since_at || created_at || Time.current
      reason_code = pending_reason_code_for(pipeline: pipeline, blocking_step: blocking_step)
      queue_name = queue_name_for(blocking_step: blocking_step)
      estimated_ready_at =
        estimate_ready_at_for(
          queue_name: queue_name,
          blocking_step: blocking_step,
          existing_blocking_step: existing_blocking_step,
          existing_estimated_ready_at: existing_estimated_ready_at
        )

      {
        ai_pipeline_run_id: pipeline["run_id"].to_s.presence,
        ai_blocking_step: blocking_step,
        ai_pending_reason_code: reason_code,
        ai_pending_since_at: pending_since_at,
        ai_next_retry_at: existing_next_retry_at,
        ai_estimated_ready_at: estimated_ready_at
      }
    rescue StandardError
      terminal_pending_projection(pipeline: pipeline)
    end

    def terminal_pending_projection(pipeline:)
      {
        ai_pipeline_run_id: pipeline.to_h["run_id"].to_s.presence,
        ai_blocking_step: nil,
        ai_pending_reason_code: nil,
        ai_pending_since_at: nil,
        ai_next_retry_at: nil,
        ai_estimated_ready_at: nil
      }
    end

    def blocking_step_for(pipeline:)
      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      required = Array(pipeline["required_steps"]).map(&:to_s)
      required.find do |step|
        !TERMINAL_STATUSES.include?(steps.dig(step, "status").to_s)
      end
    rescue StandardError
      nil
    end

    def pending_reason_code_for(pipeline:, blocking_step:)
      return "pipeline_finalizing" if blocking_step.to_s.blank?

      status = pipeline.dig("steps", blocking_step.to_s, "status").to_s
      case status
      when "queued"
        "queued_#{blocking_step}"
      when "running"
        "running_#{blocking_step}"
      when "failed"
        "failed_#{blocking_step}"
      else
        "waiting_#{blocking_step}"
      end
    rescue StandardError
      "pipeline_running"
    end

    def queue_name_for(blocking_step:)
      service_key =
        if blocking_step.to_s.present?
          STEP_TO_QUEUE_SERVICE_KEY[blocking_step.to_s]
        else
          :pipeline_orchestration
        end
      name = Ops::AiServiceQueueRegistry.queue_name_for(service_key)
      name.to_s.presence || Ops::AiServiceQueueRegistry.queue_name_for(:pipeline_orchestration).to_s
    rescue StandardError
      Ops::AiServiceQueueRegistry.queue_name_for(:pipeline_orchestration).to_s
    end

    def estimate_ready_at_for(queue_name:, blocking_step:, existing_blocking_step:, existing_estimated_ready_at:)
      if existing_estimated_ready_at.present? && existing_blocking_step.to_s == blocking_step.to_s
        return existing_estimated_ready_at
      end

      seconds = estimated_total_seconds_for_queue(queue_name: queue_name)
      Time.current + seconds.seconds
    rescue StandardError
      Time.current + DEFAULT_PENDING_ESTIMATE_SECONDS.seconds
    end

    def estimated_total_seconds_for_queue(queue_name:)
      estimate = Ops::QueueProcessingEstimator.estimate_for_queue(
        queue_name: queue_name.to_s,
        backend: "sidekiq"
      )
      value = estimate.to_h[:estimated_new_item_total_seconds].to_f
      return DEFAULT_PENDING_ESTIMATE_SECONDS if value <= 0.0

      value.round.clamp(5, 7_200)
    rescue StandardError
      DEFAULT_PENDING_ESTIMATE_SECONDS
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def normalize_task_flags(task_flags)
      incoming = deep_stringify(task_flags.is_a?(Hash) ? task_flags : {})
      normalized = DEFAULT_TASK_FLAGS.deep_dup

      incoming.each do |key, value|
        next unless normalized.key?(key)

        normalized[key] = ActiveModel::Type::Boolean.new.cast(value)
      end

      normalized["run_video"] = false unless video_media_available?
      normalized
    end

    def required_steps_for(flags:)
      TASK_TO_STEP.each_with_object([]) do |(flag_key, step_key), steps|
        steps << step_key if ActiveModel::Type::Boolean.new.cast(flags[flag_key])
      end
    end

    def video_media_available?
      return false unless post.media.attached?

      post.media.blob&.content_type.to_s.start_with?("video/")
    rescue StandardError
      false
    end

    def build_initial_steps(required_steps:, at:)
      STEP_KEYS.each_with_object({}) do |step, out|
        if required_steps.include?(step)
          out[step] = {
            "status" => "pending",
            "attempts" => 0,
            "queue_name" => nil,
            "active_job_id" => nil,
            "started_at" => nil,
            "finished_at" => nil,
            "result" => {},
            "error" => nil,
            "created_at" => at
          }
        else
          out[step] = {
            "status" => "skipped",
            "attempts" => 0,
            "result" => { "reason" => "task_disabled" },
            "created_at" => at,
            "finished_at" => at
          }
        end
      end
    end

    def metadata_for(record)
      value = record.metadata
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), out|
          out[key.to_s] = deep_stringify(child)
        end
      when Array
        value.map { |child| deep_stringify(child) }
      else
        value
      end
    end

    def iso_timestamp
      Time.current.iso8601(3)
    end
  end
end
