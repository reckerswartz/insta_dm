require "json"

module Ops
  class SidekiqJobStateTracker
    META_KEY = "state_tracker".freeze

    class << self
      def now_ms
        (Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) rescue (Time.now.to_f * 1000).to_i).to_i
      end

      def payload_hash(payload)
        return payload if payload.is_a?(Hash)
        return {} unless payload.is_a?(String)

        JSON.parse(payload)
      rescue StandardError
        {}
      end

      def log_transition(state:, msg:, queue:, now_ms: now_ms, extra_payload: {})
        info = extract_job_info(msg: msg, queue: queue)
        queue_wait_ms = queue_wait_ms(msg: msg, now_ms: now_ms)
        processing_duration_ms = processing_duration_ms(msg: msg, now_ms: now_ms)
        total_time_ms = total_time_ms(msg: msg, now_ms: now_ms)

        payload = {
          transition: state.to_s,
          sidekiq_jid: info[:sidekiq_jid],
          active_job_id: info[:active_job_id],
          provider_job_id: info[:sidekiq_jid],
          sidekiq_class: info[:sidekiq_class],
          job_class: info[:job_class],
          queue_name: info[:queue_name],
          retry_count: msg["retry_count"],
          queue_wait_ms: queue_wait_ms,
          processing_duration_ms: processing_duration_ms,
          total_time_ms: total_time_ms,
          transition_recorded_at_ms: now_ms
        }.merge(info[:context]).merge(queue_prediction(msg: msg)).merge(extra_payload).compact

        if state.to_s == "failed"
          Ops::StructuredLogger.error(event: "job.state_transition", payload: payload)
        else
          Ops::StructuredLogger.info(event: "job.state_transition", payload: payload)
        end

        # Persist terminal transition timings for queue ETA forecasting.
        if payload[:transition].to_s.in?(%w[completed failed])
          Ops::JobExecutionMetricsRecorder.record_transition(payload: payload)
        end
      rescue StandardError
        nil
      end

      def mark_queued!(msg:, queue:, now_ms:)
        meta = metadata(msg)
        queue_name = queue.to_s
        meta["queued_at_ms"] ||= now_ms
        meta["queue_name"] ||= queue_name
        meta["enqueued_pid"] ||= Process.pid
        prediction = estimate_queue_timing(queue_name: queue_name)
        if prediction.present?
          meta["predicted_wait_seconds"] ||= prediction[:estimated_new_item_wait_seconds]
          meta["predicted_total_seconds"] ||= prediction[:estimated_new_item_total_seconds]
          meta["prediction_confidence"] ||= prediction[:confidence].to_s.presence
          meta["prediction_sample_size"] ||= prediction[:sample_size].to_i
          meta["prediction_captured_at_ms"] ||= now_ms
        end
      end

      def mark_reserved!(msg:, now_ms:)
        meta = metadata(msg)
        meta["reserved_at_ms"] ||= now_ms
      end

      def mark_processing!(msg:, now_ms:)
        meta = metadata(msg)
        meta["processing_started_at_ms"] ||= now_ms
      end

      def queue_wait_ms(msg:, now_ms:)
        meta = metadata(msg)
        queued_at = meta["queued_at_ms"] || fallback_enqueued_at_ms(msg)
        reserved_at = meta["reserved_at_ms"] || now_ms
        return nil unless queued_at

        (reserved_at.to_i - queued_at.to_i).clamp(0, 7.days.in_milliseconds)
      rescue StandardError
        nil
      end

      def processing_duration_ms(msg:, now_ms:)
        started_at = metadata(msg)["processing_started_at_ms"]
        return nil unless started_at

        (now_ms.to_i - started_at.to_i).clamp(0, 7.days.in_milliseconds)
      rescue StandardError
        nil
      end

      def total_time_ms(msg:, now_ms:)
        queued_at = metadata(msg)["queued_at_ms"] || fallback_enqueued_at_ms(msg)
        return nil unless queued_at

        (now_ms.to_i - queued_at.to_i).clamp(0, 7.days.in_milliseconds)
      rescue StandardError
        nil
      end

      def queue_prediction(msg:)
        meta = metadata(msg)
        {
          predicted_wait_seconds: float_or_nil(meta["predicted_wait_seconds"]),
          predicted_total_seconds: float_or_nil(meta["predicted_total_seconds"]),
          prediction_confidence: meta["prediction_confidence"].to_s.presence,
          prediction_sample_size: integer_or_nil(meta["prediction_sample_size"]),
          prediction_captured_at_ms: integer_or_nil(meta["prediction_captured_at_ms"])
        }.compact
      rescue StandardError
        {}
      end

      private

      def estimate_queue_timing(queue_name:)
        return nil if queue_name.to_s.blank?

        Ops::QueueProcessingEstimator.estimate_for_queue(
          queue_name: queue_name.to_s,
          backend: "sidekiq"
        )
      rescue StandardError
        nil
      end

      def metadata(msg)
        return {} unless msg.is_a?(Hash)

        msg[META_KEY] = {} unless msg[META_KEY].is_a?(Hash)
        msg[META_KEY]
      end

      def fallback_enqueued_at_ms(msg)
        enqueued_at = msg["enqueued_at"]
        return nil unless enqueued_at

        (enqueued_at.to_f * 1000).to_i
      rescue StandardError
        nil
      end

      def extract_job_info(msg:, queue:)
        sidekiq_class = msg["class"].to_s
        jid = msg["jid"].to_s
        wrapped = active_job_wrapper_payload(msg)
        if wrapped
          arguments = wrapped["arguments"]
          context = extract_context(arguments)
          {
            sidekiq_jid: jid,
            sidekiq_class: sidekiq_class,
            job_class: wrapped["job_class"].to_s,
            active_job_id: wrapped["job_id"].to_s,
            queue_name: wrapped["queue_name"].to_s.presence || queue.to_s,
            context: context
          }
        else
          context = extract_context(msg["args"])
          {
            sidekiq_jid: jid,
            sidekiq_class: sidekiq_class,
            job_class: sidekiq_class,
            active_job_id: jid,
            queue_name: queue.to_s,
            context: context
          }
        end
      rescue StandardError
        {
          sidekiq_jid: msg["jid"].to_s,
          sidekiq_class: msg["class"].to_s,
          job_class: msg["class"].to_s,
          active_job_id: msg["jid"].to_s,
          queue_name: queue.to_s,
          context: {}
        }
      end

      def active_job_wrapper_payload(msg)
        return nil unless msg["class"].to_s == "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
        return nil unless msg["args"].is_a?(Array)

        first = msg["args"].first
        first.is_a?(Hash) ? first : nil
      end

      def extract_context(arguments)
        first = arguments.is_a?(Array) ? arguments.first : nil
        return {} unless first.is_a?(Hash)

        {
          instagram_account_id: first["instagram_account_id"] || first[:instagram_account_id],
          instagram_profile_id: first["instagram_profile_id"] || first[:instagram_profile_id],
          instagram_profile_post_id: first["instagram_profile_post_id"] || first[:instagram_profile_post_id]
        }.compact
      rescue StandardError
        {}
      end

      def integer_or_nil(value)
        return nil if value.nil?

        Integer(value)
      rescue StandardError
        nil
      end

      def float_or_nil(value)
        return nil if value.nil?

        Float(value)
      rescue StandardError
        nil
      end
    end

    class ClientMiddleware
      def call(_worker_class, msg, queue, _redis_pool)
        now = SidekiqJobStateTracker.now_ms
        SidekiqJobStateTracker.mark_queued!(msg: msg, queue: queue, now_ms: now)
        result = yield
        SidekiqJobStateTracker.log_transition(state: :queued, msg: msg, queue: queue, now_ms: now)
        result
      end
    end

    class ServerMiddleware
      def call(_worker, msg, queue)
        reserved_at = SidekiqJobStateTracker.now_ms
        SidekiqJobStateTracker.mark_reserved!(msg: msg, now_ms: reserved_at)
        SidekiqJobStateTracker.log_transition(state: :reserved, msg: msg, queue: queue, now_ms: reserved_at)

        processing_started_at = SidekiqJobStateTracker.now_ms
        SidekiqJobStateTracker.mark_processing!(msg: msg, now_ms: processing_started_at)
        SidekiqJobStateTracker.log_transition(state: :processing, msg: msg, queue: queue, now_ms: processing_started_at)

        yield

        completed_at = SidekiqJobStateTracker.now_ms
        SidekiqJobStateTracker.log_transition(state: :completed, msg: msg, queue: queue, now_ms: completed_at)
      rescue StandardError => e
        failed_at = SidekiqJobStateTracker.now_ms
        SidekiqJobStateTracker.log_transition(
          state: :failed,
          msg: msg,
          queue: queue,
          now_ms: failed_at,
          extra_payload: {
            error_class: e.class.name,
            error_message: e.message.to_s.byteslice(0, 500)
          }
        )
        raise
      end
    end
  end
end
