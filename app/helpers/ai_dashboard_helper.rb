module AiDashboardHelper
  def get_default_test_for_service(service)
    case service.to_s
    when 'vision'
      'labels'
    when 'face'
      'detection'
    when 'ocr'
      'text_extraction'
    when 'whisper'
      'transcription'
    when 'video'
      'analysis'
    else
      'basic'
    end
  end
end
