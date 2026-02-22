# frozen_string_literal: true

module LlmComment
  class StoryIntelligencePayloadResolver
    MAX_WAIT_SECONDS = ENV.fetch("LLM_COMMENT_SHARED_PAYLOAD_WAIT_SECONDS", "30").to_i.clamp(5, 120)
    WAIT_POLL_SECONDS = 0.25

    def initialize(event:, pipeline_state:, pipeline_run_id:, active_job_id:)
      @event = event
      @pipeline_state = pipeline_state
      @pipeline_run_id = pipeline_run_id.to_s
      @active_job_id = active_job_id.to_s
    end

    def fetch!
      attempts = (MAX_WAIT_SECONDS / WAIT_POLL_SECONDS).to_i
      attempts = 1 if attempts <= 0

      attempts.times do
        decision = pipeline_state.claim_shared_payload!(
          run_id: pipeline_run_id,
          active_job_id: active_job_id
        )

        case decision[:status].to_sym
        when :ready
          return deep_symbolize(decision[:payload])
        when :owner
          payload = build_payload!
          pipeline_state.store_shared_payload!(
            run_id: pipeline_run_id,
            active_job_id: active_job_id,
            payload: payload
          )
          return payload
        else
          sleep WAIT_POLL_SECONDS
        end
      end

      payload = build_payload!
      pipeline_state.store_shared_payload!(
        run_id: pipeline_run_id,
        active_job_id: active_job_id,
        payload: payload
      )
      payload
    rescue StandardError => e
      pipeline_state.mark_shared_payload_failed!(
        run_id: pipeline_run_id,
        active_job_id: active_job_id,
        error: "#{e.class}: #{e.message}".byteslice(0, 320)
      )
      raise
    end

    private

    attr_reader :event, :pipeline_state, :pipeline_run_id, :active_job_id

    def build_payload!
      payload = event.local_story_intelligence_payload
      payload = deep_symbolize(payload.is_a?(Hash) ? payload : {})
      event.persist_local_story_intelligence!(payload)
      payload
    end

    def deep_symbolize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), out|
          out[key.to_sym] = deep_symbolize(child)
        end
      when Array
        value.map { |child| deep_symbolize(child) }
      else
        value
      end
    end
  end
end
