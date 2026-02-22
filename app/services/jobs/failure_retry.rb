require "json"

module Jobs
  class FailureRetry
    class RetryError < StandardError; end
    DEFAULT_AUTO_LIMIT = 20
    DEFAULT_AUTO_MAX_ATTEMPTS = 3
    DEFAULT_AUTO_COOLDOWN = 10.minutes
    PIPELINE_STEP_BY_JOB_CLASS = {
      "ProcessPostVisualAnalysisJob" => "visual",
      "ProcessPostFaceAnalysisJob" => "face",
      "ProcessPostOcrAnalysisJob" => "ocr",
      "ProcessPostVideoAnalysisJob" => "video",
      "ProcessPostMetadataTaggingJob" => "metadata",
      "FinalizePostAnalysisPipelineJob" => nil
    }.freeze

    class << self
      def enqueue!(failure, source: "manual")
        raise RetryError, "Failure record is required" unless failure
        raise RetryError, "Authentication failures must not be retried" if failure.auth_failure?
        raise RetryError, "Failure is marked as non-retryable" unless failure.retryable_now?

        job_class = failure.job_class.to_s.safe_constantize
        raise RetryError, "Unknown job class: #{failure.job_class}" unless job_class

        payload = parse_arguments(failure.arguments_json)
        raise RetryError, "Job is already queued or running; retry skipped to avoid duplicate execution" if retry_in_flight?(failure: failure, payload: payload)
        raise RetryError, "Failure is no longer actionable for retry" unless retry_actionable?(failure: failure, payload: payload)

        job = perform_later(job_class: job_class, payload: payload)
        mark_retry_enqueued!(failure: failure, source: source, job: job)

        Ops::LiveUpdateBroadcaster.broadcast!(
          topic: "jobs_changed",
          account_id: failure.instagram_account_id,
          payload: { action: "retry_enqueued", failed_job_id: failure.id, new_job_id: job.job_id },
          throttle_key: "jobs_changed",
          throttle_seconds: 0
        )

        job
      end

      def enqueue_automatic_retries!(limit: DEFAULT_AUTO_LIMIT, max_attempts: DEFAULT_AUTO_MAX_ATTEMPTS, cooldown: DEFAULT_AUTO_COOLDOWN)
        cap = limit.to_i.clamp(1, 200)
        attempts_cap = max_attempts.to_i.clamp(1, 10)
        cool_down = normalize_cooldown(cooldown)

        result = { scanned: 0, enqueued: 0, skipped: 0, errors: 0 }
        each_retry_candidate(limit: cap * 5) do |failure|
          result[:scanned] += 1

          unless eligible_for_auto_retry?(failure: failure, max_attempts: attempts_cap, cooldown: cool_down)
            result[:skipped] += 1
            next
          end

          begin
            enqueue!(failure, source: "auto")
            result[:enqueued] += 1
          rescue RetryError, StandardError => e
            mark_retry_error!(failure: failure, error: e)
            result[:errors] += 1
          end

          break if result[:enqueued] >= cap
        end

        Ops::StructuredLogger.info(
          event: "jobs.failure_retry.auto_batch",
          payload: result.merge(limit: cap, max_attempts: attempts_cap, cooldown_seconds: cool_down.to_i)
        )

        result
      end

      private

      def parse_arguments(raw)
        return [] if raw.blank?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : [parsed]
      rescue StandardError
        []
      end

      def perform_later(job_class:, payload:)
        if payload.length == 1 && payload.first.is_a?(Hash)
          job_class.perform_later(**payload.first.deep_symbolize_keys)
        else
          job_class.perform_later(*payload)
        end
      rescue ArgumentError
        job_class.perform_later(*payload)
      end

      def each_retry_candidate(limit:)
        scope = BackgroundJobFailure.where(retryable: true).where.not(failure_kind: "authentication")
        scope = scope.where("occurred_at >= ?", 72.hours.ago)
        scope.order(occurred_at: :desc, id: :desc).limit(limit).to_a.each do |failure|
          yield failure
        end
      end

      def eligible_for_auto_retry?(failure:, max_attempts:, cooldown:)
        state = retry_state_for(failure)
        attempts = state["attempts"].to_i
        return false if attempts >= max_attempts
        return false if retry_in_flight?(failure: failure)
        return false unless retry_actionable?(failure: failure)

        last_retry_at = parse_time(state["last_retry_at"])
        return true if last_retry_at.blank?

        last_retry_at <= cooldown.ago
      end

      def retry_state_for(failure)
        metadata = failure.metadata.is_a?(Hash) ? failure.metadata : {}
        raw = metadata["retry_state"].is_a?(Hash) ? metadata["retry_state"] : {}
        raw.stringify_keys
      rescue StandardError
        {}
      end

      def mark_retry_enqueued!(failure:, source:, job:)
        metadata = failure.metadata.is_a?(Hash) ? failure.metadata.deep_dup : {}
        state = retry_state_for(failure)
        attempts = state["attempts"].to_i + 1
        state["attempts"] = attempts
        state["last_retry_at"] = Time.current.iso8601
        state["last_retry_job_id"] = job.job_id
        state["last_retry_source"] = source.to_s
        state["last_retry_error"] = nil

        metadata["retry_state"] = state
        failure.update_columns(metadata: metadata, updated_at: Time.current)
      rescue StandardError
        nil
      end

      def mark_retry_error!(failure:, error:)
        metadata = failure.metadata.is_a?(Hash) ? failure.metadata.deep_dup : {}
        state = retry_state_for(failure)
        state["last_retry_error"] = "#{error.class}: #{error.message}"
        state["last_retry_attempted_at"] = Time.current.iso8601
        metadata["retry_state"] = state
        failure.update_columns(metadata: metadata, updated_at: Time.current)
      rescue StandardError
        nil
      end

      def parse_time(raw)
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue StandardError
        nil
      end

      def normalize_cooldown(value)
        return value if value.is_a?(ActiveSupport::Duration)

        value.to_i.seconds
      rescue StandardError
        DEFAULT_AUTO_COOLDOWN
      end

      def retry_actionable?(failure:, payload: nil)
        return false if llm_generation_still_processing?(failure: failure, payload: payload)
        return true unless PIPELINE_STEP_BY_JOB_CLASS.key?(failure.job_class.to_s)

        args = pipeline_args(payload || parse_arguments(failure.arguments_json))
        return true unless args.present?

        pipeline_run_id = args["pipeline_run_id"].to_s
        return true if pipeline_run_id.blank?

        post = pipeline_post_from_args(args)
        return false unless post

        pipeline_state = Ai::PostAnalysisPipelineState.new(post: post)
        return false if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)

        step = PIPELINE_STEP_BY_JOB_CLASS[failure.job_class.to_s]
        return true if step.blank?

        !pipeline_state.step_terminal?(run_id: pipeline_run_id, step: step)
      rescue StandardError
        true
      end

      def retry_in_flight?(failure:, payload: nil)
        args = payload || parse_arguments(failure.arguments_json)
        return true if llm_generation_still_processing?(failure: failure, payload: args)
        return false unless sidekiq_adapter?

        active_job_id = failure.active_job_id.to_s
        return false if active_job_id.blank?

        require "sidekiq/api"
        queues = Sidekiq::Queue.all

        Sidekiq::Workers.new.any? { |_pid, _tid, work| work["payload"].to_s.include?(active_job_id) } ||
          queues.any? { |queue| queue.any? { |job| job.item.to_s.include?(active_job_id) } } ||
          Sidekiq::RetrySet.new.any? { |job| job.item.to_s.include?(active_job_id) } ||
          Sidekiq::ScheduledSet.new.any? { |job| job.item.to_s.include?(active_job_id) }
      rescue StandardError
        false
      end

      def llm_generation_still_processing?(failure:, payload:)
        return false unless failure.job_class.to_s == "GenerateLlmCommentJob"

        args = pipeline_args(payload)
        event_id = args["instagram_profile_event_id"].to_i
        return false if event_id <= 0

        event = InstagramProfileEvent.find_by(id: event_id)
        return false unless event

        event.llm_comment_status.to_s.in?(%w[queued running])
      rescue StandardError
        false
      end

      def sidekiq_adapter?
        Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
      rescue StandardError
        false
      end

      def pipeline_args(payload)
        return {} unless payload.is_a?(Array)

        first = payload.first
        return {} unless first.is_a?(Hash)

        first.stringify_keys
      end

      def pipeline_post_from_args(args)
        post_id = args["instagram_profile_post_id"].to_i
        return nil if post_id <= 0

        profile_id = args["instagram_profile_id"].to_i
        account_id = args["instagram_account_id"].to_i

        scope = InstagramProfilePost.where(id: post_id)
        scope = scope.where(instagram_profile_id: profile_id) if profile_id.positive?
        scope = scope.where(instagram_account_id: account_id) if account_id.positive?
        scope.first
      end
    end
  end
end
