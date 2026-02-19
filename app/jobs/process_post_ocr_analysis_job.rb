require "timeout"

class ProcessPostOcrAnalysisJob < PostAnalysisPipelineJob
  queue_as :ai_ocr_queue

  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_OCR_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:, defer_attempt: 0)
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    account = context[:account]
    post = context[:post]
    pipeline_state = context[:pipeline_state]

    unless resource_available?(defer_attempt: defer_attempt, context: context, pipeline_run_id: pipeline_run_id)
      return
    end

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: "ocr",
      queue_name: queue_name,
      active_job_id: job_id
    )

    reused = reuse_ocr_from_face_metadata(post: post)
    result =
      if reused
        reused
      else
        context_builder = Ai::PostAnalysisContextBuilder.new(profile: context[:profile], post: post)
        image_payload = context_builder.detection_image_payload
        if ActiveModel::Type::Boolean.new.cast(image_payload[:skipped])
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
          Timeout.timeout(ocr_timeout_seconds) do
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
      end

    persist_ocr_result!(post: post, result: result)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "ocr",
      status: "succeeded",
      result: {
        skipped: ActiveModel::Type::Boolean.new.cast(result[:skipped]),
        text_present: result[:ocr_text].to_s.present?,
        ocr_blocks_count: Array(result[:ocr_blocks]).length,
        source: result.dig(:metadata, :source) || result.dig("metadata", "source")
      }.compact
    )
  rescue StandardError => e
    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "ocr",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "ocr_analysis_failed"
      }
    )
    raise
  ensure
    if context
      enqueue_pipeline_finalizer(
        account: context[:account],
        profile: context[:profile],
        post: context[:post],
        pipeline_run_id: pipeline_run_id
      )
    end
  end

  private

  def resource_available?(defer_attempt:, context:, pipeline_run_id:)
    guard = Ops::ResourceGuard.allow_ai_task?(task: "ocr", queue_name: queue_name, critical: false)
    return true if ActiveModel::Type::Boolean.new.cast(guard[:allow])

    if defer_attempt.to_i >= MAX_DEFER_ATTEMPTS
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "ocr",
        status: "failed",
        error: "resource_guard_exhausted: #{guard[:reason]}",
        result: {
          reason: "resource_constraints",
          snapshot: guard[:snapshot]
        }
      )
      return false
    end

    retry_seconds = guard[:retry_in_seconds].to_i
    retry_seconds = 20 if retry_seconds <= 0

    context[:pipeline_state].mark_step_queued!(
      run_id: pipeline_run_id,
      step: "ocr",
      queue_name: queue_name,
      active_job_id: job_id,
      result: {
        reason: "resource_constrained",
        defer_attempt: defer_attempt.to_i,
        retry_in_seconds: retry_seconds,
        snapshot: guard[:snapshot]
      }
    )

    self.class.set(wait: retry_seconds.seconds).perform_later(
      instagram_account_id: context[:account].id,
      instagram_profile_id: context[:profile].id,
      instagram_profile_post_id: context[:post].id,
      pipeline_run_id: pipeline_run_id,
      defer_attempt: defer_attempt.to_i + 1
    )

    false
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

  def ocr_timeout_seconds
    ENV.fetch("AI_OCR_TIMEOUT_SECONDS", 150).to_i.clamp(15, 360)
  end
end
