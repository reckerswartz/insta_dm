# frozen_string_literal: true

class ProcessStoryCommentOcrJob < StoryCommentStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:ocr_analysis)

  private

  def step_key
    "ocr_analysis"
  end

  def running_message
    "OCR processing started."
  end

  def failed_message
    "OCR processing failed."
  end

  def failure_reason
    "ocr_stage_failed"
  end

  def completed_message(summary:)
    summary[:text_present] ? "OCR processing completed." : "OCR completed with limited text."
  end

  def extract_summary(payload:, event:, context:)
    ocr_text = payload[:ocr_text].to_s.presence
    ocr_blocks = Array(payload[:ocr_blocks]).select { |row| row.is_a?(Hash) }.first(120)

    {
      source: payload[:source].to_s.presence,
      text_present: ocr_text.present?,
      ocr_blocks_count: ocr_blocks.length
    }
  end

  def completion_details(summary:)
    {
      text_present: summary[:text_present],
      ocr_blocks_count: summary[:ocr_blocks_count]
    }
  end
end
