# frozen_string_literal: true

require "securerandom"

module LlmComment
  class ParallelPipelineState
    STEP_KEYS = %w[
      ocr_analysis
      vision_detection
      face_recognition
      metadata_extraction
    ].freeze
    TERMINAL_STEP_STATUSES = %w[succeeded failed skipped].freeze
    PIPELINE_TERMINAL_STATUSES = %w[completed failed].freeze
    SHARED_PAYLOAD_BUILD_STALE_SECONDS = ENV.fetch("LLM_COMMENT_SHARED_PAYLOAD_STALE_SECONDS", "180").to_i.clamp(30, 900)

    def initialize(event:)
      @event = event
    end

    attr_reader :event

    def start!(provider:, model:, requested_by:, source_job:, active_job_id: nil, regenerate_all: false, run_id: SecureRandom.uuid)
      event.with_lock do
        event.reload
        metadata = normalized_metadata
        existing = metadata["parallel_pipeline"]
        if existing.is_a?(Hash) && existing["status"].to_s == "running" && existing["run_id"].to_s.present?
          return {
            run_id: existing["run_id"].to_s,
            started: false,
            reused: true,
            pipeline: existing
          }
        end

        now = iso_timestamp
        resume_source = resumable_pipeline(existing: existing, regenerate_all: regenerate_all)
        pipeline = {
          "run_id" => run_id.to_s,
          "status" => "running",
          "provider" => provider.to_s,
          "model" => model.to_s.presence,
          "requested_by" => requested_by.to_s.presence,
          "source_job" => source_job.to_s.presence,
          "source_active_job_id" => active_job_id.to_s.presence,
          "resume_mode" => regenerate_all ? "regenerate_all" : (resume_source.present? ? "resume_incomplete" : "fresh"),
          "resumed_from_run_id" => resume_source.to_h["run_id"].to_s.presence,
          "created_at" => now,
          "updated_at" => now,
          "steps" => seeded_steps(previous_pipeline: resume_source, at: now),
          "shared_payload" => seeded_shared_payload(previous_pipeline: resume_source),
          "generation" => {
            "status" => "pending",
            "started_at" => nil,
            "finished_at" => nil,
            "active_job_id" => nil,
            "error" => nil
          }
        }.compact

        metadata["parallel_pipeline"] = pipeline
        event.update_columns(llm_comment_metadata: metadata, updated_at: Time.current)

        {
          run_id: run_id.to_s,
          started: true,
          reused: false,
          resumed_from_run_id: pipeline["resumed_from_run_id"],
          resume_mode: pipeline["resume_mode"],
          pipeline: pipeline
        }
      end
    end

    def pipeline_for(run_id:)
      data = current_pipeline
      return nil unless data.is_a?(Hash)
      return nil unless data["run_id"].to_s == run_id.to_s

      data
    end

    def current_pipeline
      metadata = event.reload.llm_comment_metadata
      value = metadata.is_a?(Hash) ? metadata : {}
      value["parallel_pipeline"]
    rescue StandardError
      nil
    end

    def pipeline_terminal?(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      PIPELINE_TERMINAL_STATUSES.include?(pipeline.to_h["status"].to_s)
    end

    def step_terminal?(run_id:, step:)
      TERMINAL_STEP_STATUSES.include?(step_state(run_id: run_id, step: step).to_h["status"].to_s)
    end

    def step_state(run_id:, step:)
      pipeline = pipeline_for(run_id: run_id)
      return nil unless pipeline.is_a?(Hash)

      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      steps[step.to_s]
    end

    def all_steps_terminal?(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return false unless pipeline.is_a?(Hash)

      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      STEP_KEYS.all? do |step|
        TERMINAL_STEP_STATUSES.include?(steps.dig(step, "status").to_s)
      end
    end

    def failed_steps(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return [] unless pipeline.is_a?(Hash)

      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      STEP_KEYS.select { |step| steps.dig(step, "status").to_s == "failed" }
    end

    def steps_requiring_execution(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return STEP_KEYS if pipeline.blank?

      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      STEP_KEYS.select do |step|
        status = steps.dig(step, "status").to_s
        !TERMINAL_STEP_STATUSES.include?(status)
      end
    rescue StandardError
      STEP_KEYS
    end

    def step_rollup(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return {} unless pipeline.is_a?(Hash)

      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      STEP_KEYS.each_with_object({}) do |step, out|
        row = steps[step].is_a?(Hash) ? steps[step] : {}
        out[step] = {
          "status" => row["status"].to_s.presence || "pending",
          "attempts" => row["attempts"].to_i,
          "queue_name" => row["queue_name"].to_s.presence,
          "queued_at" => row["queued_at"].to_s.presence || row["created_at"].to_s.presence,
          "started_at" => row["started_at"].to_s.presence,
          "finished_at" => row["finished_at"].to_s.presence,
          "queue_wait_ms" => row["queue_wait_ms"],
          "run_duration_ms" => row["run_duration_ms"],
          "total_duration_ms" => row["total_duration_ms"],
          "error" => row["error"].to_s.presence
        }.compact
      end
    end

    def pipeline_timing(run_id:)
      pipeline = pipeline_for(run_id: run_id)
      return {} unless pipeline.is_a?(Hash)

      created_at = parse_time(pipeline["created_at"])
      finished_at = parse_time(pipeline["finished_at"])
      generation_started_at = parse_time(pipeline.dig("generation", "started_at"))
      generation_finished_at = parse_time(pipeline.dig("generation", "finished_at"))

      {
        "pipeline_duration_ms" => duration_ms(start_time: created_at, end_time: finished_at),
        "generation_duration_ms" => duration_ms(start_time: generation_started_at, end_time: generation_finished_at)
      }.compact
    end

    def mark_step_queued!(run_id:, step:, queue_name:, active_job_id:, result: nil)
      mark_step!(
        run_id: run_id,
        step: step,
        status: "queued",
        queue_name: queue_name,
        active_job_id: active_job_id,
        queued_at: iso_timestamp,
        result: result
      )
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

    def mark_step_completed!(run_id:, step:, status:, result: nil, error: nil)
      normalized_status = status.to_s
      normalized_status = "failed" unless (TERMINAL_STEP_STATUSES + %w[pending queued running]).include?(normalized_status)

      mark_step!(
        run_id: run_id,
        step: step,
        status: normalized_status,
        result: result,
        error: error,
        finished_at: iso_timestamp
      )
    end

    def mark_generation_started!(run_id:, active_job_id:)
      acquired = false
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        generation = pipeline["generation"].is_a?(Hash) ? pipeline["generation"] : {}
        status = generation["status"].to_s
        if status.in?(%w[running completed])
          acquired = false
          next
        end

        generation["status"] = "running"
        generation["started_at"] = iso_timestamp
        generation["finished_at"] = nil
        generation["active_job_id"] = active_job_id.to_s.presence
        generation["error"] = nil
        pipeline["generation"] = generation
        acquired = true
      end
      acquired
    end

    def mark_generation_failed!(run_id:, active_job_id:, error:)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        generation = pipeline["generation"].is_a?(Hash) ? pipeline["generation"] : {}
        generation["status"] = "failed"
        generation["started_at"] = generation["started_at"].to_s.presence || iso_timestamp
        generation["finished_at"] = iso_timestamp
        generation["active_job_id"] = active_job_id.to_s.presence
        generation["error"] = error.to_s.presence
        pipeline["generation"] = generation
      end
    end

    def mark_pipeline_finished!(run_id:, status:, details: nil)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        pipeline["status"] = status.to_s
        pipeline["updated_at"] = iso_timestamp
        pipeline["finished_at"] = iso_timestamp
        detail_row = details.is_a?(Hash) ? deep_stringify(details) : {}
        generation = pipeline["generation"].is_a?(Hash) ? pipeline["generation"] : {}
        if status.to_s == "completed"
          generation["status"] = "completed"
          generation["finished_at"] = iso_timestamp
          generation["error"] = nil
        elsif status.to_s == "failed"
          generation["status"] = "failed" if generation["status"].to_s.blank? || generation["status"].to_s == "running"
          generation["finished_at"] = iso_timestamp
        end
        pipeline["generation"] = generation

        timing = {
          "pipeline_duration_ms" => duration_ms(
            start_time: parse_time(pipeline["created_at"]),
            end_time: parse_time(pipeline["finished_at"])
          ),
          "generation_duration_ms" => duration_ms(
            start_time: parse_time(generation["started_at"]),
            end_time: parse_time(generation["finished_at"])
          )
        }.compact
        pipeline["details"] = detail_row.merge(timing) if detail_row.present? || timing.present?
      end
    end

    def claim_shared_payload!(run_id:, active_job_id:)
      event.with_lock do
        event.reload
        metadata = normalized_metadata
        pipeline = metadata["parallel_pipeline"]
        return { status: :wait } unless pipeline.is_a?(Hash)
        return { status: :wait } unless pipeline["run_id"].to_s == run_id.to_s

        shared = pipeline["shared_payload"].is_a?(Hash) ? pipeline["shared_payload"] : {}
        shared_status = shared["status"].to_s
        payload = shared["payload"]

        if shared_status == "ready" && payload.is_a?(Hash)
          return {
            status: :ready,
            payload: payload
          }
        end

        if shared_status == "building" && !shared_payload_stale?(shared) && shared["builder_job_id"].to_s.present? &&
            shared["builder_job_id"].to_s != active_job_id.to_s
          return { status: :wait }
        end

        pipeline["shared_payload"] = {
          "status" => "building",
          "builder_job_id" => active_job_id.to_s.presence,
          "started_at" => iso_timestamp,
          "ready_at" => nil,
          "failed_at" => nil,
          "error" => nil,
          "payload" => nil
        }.compact
        pipeline["updated_at"] = iso_timestamp
        metadata["parallel_pipeline"] = pipeline
        event.update_columns(llm_comment_metadata: metadata, updated_at: Time.current)
        { status: :owner }
      end
    end

    def store_shared_payload!(run_id:, active_job_id:, payload:)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        pipeline["shared_payload"] = {
          "status" => "ready",
          "builder_job_id" => active_job_id.to_s.presence,
          "started_at" => pipeline.dig("shared_payload", "started_at").to_s.presence,
          "ready_at" => iso_timestamp,
          "failed_at" => nil,
          "error" => nil,
          "payload" => deep_stringify(payload)
        }.compact
      end
    end

    def mark_shared_payload_failed!(run_id:, active_job_id:, error:)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        pipeline["shared_payload"] = {
          "status" => "failed",
          "builder_job_id" => active_job_id.to_s.presence,
          "started_at" => pipeline.dig("shared_payload", "started_at").to_s.presence,
          "ready_at" => nil,
          "failed_at" => iso_timestamp,
          "error" => error.to_s.presence
        }.compact
      end
    end

  private

    def resumable_pipeline(existing:, regenerate_all:)
      return nil if ActiveModel::Type::Boolean.new.cast(regenerate_all)
      return nil unless existing.is_a?(Hash)
      return nil if existing["run_id"].to_s.blank?
      return nil if existing["status"].to_s == "running"

      existing.deep_dup
    rescue StandardError
      nil
    end

    def seeded_steps(previous_pipeline:, at:)
      rows = initial_steps(at: at)
      return rows unless previous_pipeline.is_a?(Hash)

      previous_steps = previous_pipeline["steps"]
      return rows unless previous_steps.is_a?(Hash)

      previous_run_id = previous_pipeline["run_id"].to_s.presence
      STEP_KEYS.each do |step|
        source = previous_steps[step]
        next unless source.is_a?(Hash)

        source_status = source["status"].to_s
        if source_status.in?(%w[succeeded skipped])
          rows[step] = build_reused_terminal_step(
            base_row: rows[step],
            source_row: source,
            source_status: source_status,
            previous_run_id: previous_run_id
          )
        else
          attempts = source["attempts"].to_i
          rows[step]["attempts"] = attempts if attempts.positive?
          rows[step]["result"] = {
            "resume_from_status" => source_status.presence || "unknown",
            "resumed_from_run_id" => previous_run_id
          }.compact
        end
      end

      rows
    rescue StandardError
      initial_steps(at: at)
    end

    def build_reused_terminal_step(base_row:, source_row:, source_status:, previous_run_id:)
      row = base_row.is_a?(Hash) ? base_row.deep_dup : {}
      row["status"] = source_status
      row["attempts"] = source_row["attempts"].to_i
      row["queue_name"] = source_row["queue_name"].to_s.presence
      row["active_job_id"] = nil
      row["queued_at"] = source_row["queued_at"].to_s.presence || source_row["created_at"].to_s.presence
      row["started_at"] = source_row["started_at"].to_s.presence
      row["finished_at"] = source_row["finished_at"].to_s.presence
      row["queue_wait_ms"] = source_row["queue_wait_ms"]
      row["run_duration_ms"] = source_row["run_duration_ms"]
      row["total_duration_ms"] = source_row["total_duration_ms"]
      row["result"] = if source_row["result"].is_a?(Hash)
        deep_stringify(source_row["result"]).merge("reused_from_run_id" => previous_run_id).compact
      else
        { "reused_from_run_id" => previous_run_id }.compact
      end
      row["error"] = nil
      row["created_at"] = source_row["created_at"].to_s.presence || row["created_at"]
      row
    end

    def seeded_shared_payload(previous_pipeline:)
      return nil unless previous_pipeline.is_a?(Hash)

      shared = previous_pipeline["shared_payload"]
      return nil unless shared.is_a?(Hash)
      return nil unless shared["status"].to_s == "ready"
      return nil unless shared["payload"].is_a?(Hash)

      {
        "status" => "ready",
        "builder_job_id" => shared["builder_job_id"].to_s.presence,
        "started_at" => shared["started_at"].to_s.presence,
        "ready_at" => shared["ready_at"].to_s.presence,
        "failed_at" => nil,
        "error" => nil,
        "payload" => deep_stringify(shared["payload"]),
        "reused_from_run_id" => previous_pipeline["run_id"].to_s.presence
      }.compact
    rescue StandardError
      nil
    end

    def initial_steps(at:)
      STEP_KEYS.each_with_object({}) do |step, rows|
        rows[step] = {
          "status" => "pending",
          "attempts" => 0,
          "queue_name" => nil,
          "active_job_id" => nil,
          "queued_at" => nil,
          "started_at" => nil,
          "finished_at" => nil,
          "queue_wait_ms" => nil,
          "run_duration_ms" => nil,
          "total_duration_ms" => nil,
          "result" => {},
          "error" => nil,
          "created_at" => at
        }
      end
    end

    def mark_step!(run_id:, step:, status:, queue_name: nil, active_job_id: nil, result: nil, error: nil, queued_at: nil, started_at: nil, finished_at: nil)
      with_pipeline_update(run_id: run_id) do |pipeline, _metadata|
        steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
        key = step.to_s
        row = steps[key].is_a?(Hash) ? steps[key] : {}

        attempts = row["attempts"].to_i
        attempts += 1 if status.to_s == "running"

        row["status"] = status.to_s
        row["queue_name"] = queue_name.to_s.presence if queue_name.present?
        row["active_job_id"] = active_job_id.to_s.presence if active_job_id.present?
        row["queued_at"] = queued_at if queued_at.present?
        row["queued_at"] = iso_timestamp if status.to_s == "queued" && row["queued_at"].to_s.blank?
        row["started_at"] = started_at if started_at.present?
        row["finished_at"] = finished_at if finished_at.present?
        row["attempts"] = attempts
        row["result"] = deep_stringify(result) if result.is_a?(Hash)
        row["error"] = error.to_s if error.present?
        derive_step_timing!(row)

        steps[key] = row
        pipeline["steps"] = steps
        pipeline["updated_at"] = iso_timestamp
      end
    end

    def with_pipeline_update(run_id:)
      event.with_lock do
        event.reload
        metadata = normalized_metadata
        pipeline = metadata["parallel_pipeline"]
        return nil unless pipeline.is_a?(Hash)
        return nil unless pipeline["run_id"].to_s == run_id.to_s

        yield(pipeline, metadata)
        metadata["parallel_pipeline"] = pipeline
        event.update_columns(llm_comment_metadata: metadata, updated_at: Time.current)
        pipeline
      end
    end

    def normalized_metadata
      value = event.llm_comment_metadata
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

    def shared_payload_stale?(row)
      started = parse_time(row["started_at"])
      return true unless started

      started < SHARED_PAYLOAD_BUILD_STALE_SECONDS.seconds.ago
    end

    def derive_step_timing!(row)
      queued_at = parse_time(row["queued_at"]) || parse_time(row["created_at"])
      started_at = parse_time(row["started_at"])
      finished_at = parse_time(row["finished_at"])

      row["queue_wait_ms"] = duration_ms(start_time: queued_at, end_time: started_at)
      row["run_duration_ms"] = duration_ms(start_time: started_at, end_time: finished_at)
      row["total_duration_ms"] = duration_ms(start_time: queued_at || started_at, end_time: finished_at)
      row
    end

    def duration_ms(start_time:, end_time:)
      return nil unless start_time.present? && end_time.present?
      return nil if end_time < start_time

      ((end_time.to_f - start_time.to_f) * 1000.0).round
    rescue StandardError
      nil
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def iso_timestamp
      Time.current.iso8601(3)
    end
  end
end
