module Ai
  # Single source of truth for whether the legacy local-AI pipeline
  # (face detection, OCR, Whisper transcription, local video analysis)
  # should execute this request. Phase 4.5 of the NVIDIA migration
  # soft-deprecated these paths in favour of a VLM-only flow; the
  # services and tables remain in place for audit/rollback, but the
  # pipeline steps default to no-oping.
  #
  # Re-enable the legacy flow for an individual shell / worker by
  # setting LEGACY_AI_PIPELINE_ENABLED=true.
  module LegacyPipelineConfig
    DEFAULT_ENABLED = false

    class << self
      def enabled?
        value = ENV.fetch("LEGACY_AI_PIPELINE_ENABLED", nil)
        return DEFAULT_ENABLED if value.nil?

        # Normalise to a strict boolean so callers can use `!enabled?` and
        # `be(false)` in rspec without surprises on empty-string env vars.
        result = ActiveModel::Type::Boolean.new.cast(value)
        result == true
      end

      def disabled?
        !enabled?
      end

      # Standard skip payload step jobs return when the legacy pipeline
      # is disabled. Keeps the pipeline state machine's "this step ran"
      # bookkeeping honest while ensuring we never actually call into
      # face/OCR/whisper/microservice code paths.
      def skip_result(step:)
        {
          skipped: true,
          reason: "legacy_pipeline_disabled",
          legacy_step: step.to_s,
          deprecated_since: "phase_4_5"
        }
      end
    end
  end
end
