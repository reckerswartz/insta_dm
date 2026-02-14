module Ai
  class ApiUsageTracker
    THREAD_CONTEXT_KEY = :ai_api_usage_context

    class << self
      def with_context(context = {})
        previous = current_context
        Thread.current[THREAD_CONTEXT_KEY] = previous.merge(context.to_h.compact)
        yield
      ensure
        Thread.current[THREAD_CONTEXT_KEY] = previous
      end

      def current_context
        Thread.current[THREAD_CONTEXT_KEY].is_a?(Hash) ? Thread.current[THREAD_CONTEXT_KEY] : {}
      end

      def track_success(provider:, operation:, category:, started_at:, instagram_account_id: nil, http_status: nil, request_units: nil, input_tokens: nil, output_tokens: nil, total_tokens: nil, metadata: {})
        create_record(
          provider: provider,
          operation: operation,
          category: category,
          status: "succeeded",
          started_at: started_at,
          instagram_account_id: instagram_account_id,
          http_status: http_status,
          request_units: request_units,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: total_tokens,
          metadata: metadata
        )
      end

      def track_failure(provider:, operation:, category:, started_at:, error:, instagram_account_id: nil, http_status: nil, request_units: nil, metadata: {})
        create_record(
          provider: provider,
          operation: operation,
          category: category,
          status: "failed",
          started_at: started_at,
          instagram_account_id: instagram_account_id,
          http_status: http_status,
          request_units: request_units,
          metadata: metadata,
          error_message: error.to_s
        )
      end

      private

      def create_record(provider:, operation:, category:, status:, started_at:, instagram_account_id:, http_status:, request_units:, input_tokens: nil, output_tokens: nil, total_tokens: nil, metadata: {}, error_message: nil)
        occurred_at = Time.current
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at.to_f) * 1000.0).round
        context = current_context
        account_id = integer_or_nil(instagram_account_id) || integer_or_nil(context[:instagram_account_id])

        AiApiCall.create!(
          instagram_account_id: account_id,
          provider: provider.to_s,
          operation: operation.to_s,
          category: normalize_category(category),
          status: status.to_s,
          http_status: integer_or_nil(http_status),
          latency_ms: latency_ms,
          request_units: integer_or_nil(request_units),
          input_tokens: integer_or_nil(input_tokens),
          output_tokens: integer_or_nil(output_tokens),
          total_tokens: integer_or_nil(total_tokens),
          error_message: error_message,
          occurred_at: occurred_at,
          metadata: (metadata.to_h.compact.presence || {}).merge(context.except(:instagram_account_id))
        )
      rescue StandardError => e
        Rails.logger.warn("[Ai::ApiUsageTracker] failed to persist usage event: #{e.class}: #{e.message}")
      end

      def normalize_category(value)
        raw = value.to_s.strip
        return raw if AiApiCall::CATEGORIES.include?(raw)

        "other"
      end

      def integer_or_nil(value)
        return nil if value.blank?

        Integer(value)
      rescue StandardError
        nil
      end
    end
  end
end
