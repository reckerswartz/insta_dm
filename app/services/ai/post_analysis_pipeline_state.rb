require "securerandom"

module Ai
  class PostAnalysisPipelineState
    STEP_KEYS = %w[visual face ocr video metadata].freeze
    TERMINAL_STATUSES = %w[succeeded failed skipped].freeze
    PIPELINE_TERMINAL_STATUSES = %w[completed failed].freeze

    DEFAULT_TASK_FLAGS = {
      "analyze_visual" => true,
      "analyze_faces" => false,
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

        post.update!(
          ai_status: "running",
          analyzed_at: nil,
          metadata: metadata
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
        row["error"] = error.to_s if error.present?

        steps[key] = row
        pipeline["steps"] = steps
        pipeline["updated_at"] = iso_timestamp
      end
    end

    def with_pipeline_update(run_id:)
      post.with_lock do
        metadata = metadata_for(post)
        pipeline = metadata["ai_pipeline"]
        return nil unless pipeline.is_a?(Hash)
        return nil unless pipeline["run_id"].to_s == run_id.to_s

        yield(pipeline, metadata)

        metadata["ai_pipeline"] = pipeline
        post.update!(metadata: metadata)
        pipeline
      end
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
