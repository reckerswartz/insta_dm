class GenerateLlmCommentJob < ApplicationJob
  queue_as :ai

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system")
    LlmComment::GenerationService.new(
      instagram_profile_event_id: instagram_profile_event_id,
      provider: provider,
      model: model,
      requested_by: requested_by
    ).call
  end
end
