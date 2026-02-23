require "timeout"

class ProcessPostOcrAnalysisJob < PostAnalysisStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:ocr_analysis)

  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_OCR_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  private

  def step_key
    "ocr"
  end

  def resource_task_name
    "ocr"
  end

  def audit_service_name
    Ai::PostOcrService.name
  end

  def max_defer_attempts
    MAX_DEFER_ATTEMPTS
  end

  def timeout_seconds
    ocr_timeout_seconds
  end

  def step_failure_reason
    "ocr_analysis_failed"
  end

  def perform_step!(context:, pipeline_run_id:, options: {})
    account = context[:account]
    post = context[:post]

    result = reuse_ocr_from_face_metadata(post: post)
    unless result
      context_builder = Ai::PostAnalysisContextBuilder.new(profile: context[:profile], post: post)
      image_payload = context_builder.detection_image_payload
      result = if ActiveModel::Type::Boolean.new.cast(image_payload[:skipped])
        {
          skipped: true,
          ocr_text: nil,
          ocr_blocks: [],
          metadata: {
            source: "post_ocr_service",
            reason: image_payload[:reason].to_s.presence || "image_payload_unavailable"
          }
        }
      else
        Ai::PostOcrService.new.extract_from_image_bytes(
          image_bytes: image_payload[:image_bytes],
          usage_context: {
            workflow: "post_analysis_pipeline",
            task: "ocr",
            post_id: post.id,
            instagram_account_id: account.id
          }
        )
      end
    end

    persist_ocr_result!(post: post, result: result)
    result
  end

  def step_completion_result(raw_result:, context:, options: {})
    {
      skipped: ActiveModel::Type::Boolean.new.cast(raw_result[:skipped]),
      text_present: raw_result[:ocr_text].to_s.present?,
      ocr_blocks_count: Array(raw_result[:ocr_blocks]).length,
      source: raw_result.dig(:metadata, :source) || raw_result.dig("metadata", "source")
    }.compact
  end

  def reuse_ocr_from_face_metadata(post:)
    face_meta = post.metadata.is_a?(Hash) ? post.metadata.dig("face_recognition") : nil
    return nil unless face_meta.is_a?(Hash)

    text = face_meta["ocr_text"].to_s.strip
    blocks = Array(face_meta["ocr_blocks"]).select { |row| row.is_a?(Hash) }
    return nil if text.blank? && blocks.empty?

    {
      skipped: false,
      ocr_text: text.presence,
      ocr_blocks: blocks.first(80),
      metadata: {
        source: "face_recognition_cache"
      }
    }
  end

  def persist_ocr_result!(post:, result:)
    post.with_lock do
      post.reload
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}

      analysis["ocr_text"] = result[:ocr_text] if result.key?(:ocr_text)
      analysis["ocr_blocks"] = Array(result[:ocr_blocks]).first(40) if result.key?(:ocr_blocks)

      metadata["ocr_analysis"] = {
        "ocr_text" => result[:ocr_text].to_s.presence,
        "ocr_blocks" => Array(result[:ocr_blocks]).first(80),
        "source" => result.dig(:metadata, :source) || result.dig("metadata", "source"),
        "reason" => result.dig(:metadata, :reason) || result.dig("metadata", "reason"),
        "error_message" => result.dig(:metadata, :error_message) || result.dig("metadata", "error_message"),
        "updated_at" => Time.current.iso8601(3)
      }.compact

      post.update!(analysis: analysis, metadata: metadata)
    end
  end

  def ocr_timeout_seconds
    ENV.fetch("AI_OCR_TIMEOUT_SECONDS", 150).to_i.clamp(15, 360)
  end
end
