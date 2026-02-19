class AppendProfileHistoryNarrativeJob < ApplicationJob
  queue_as :maintenance

  def perform(instagram_profile_event_id:, mode: "event", intelligence: nil)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event

    case mode.to_s
    when "event"
      Ai::ProfileHistoryNarrativeBuilder.append_event!(event)
    when "story_intelligence"
      payload = intelligence.is_a?(Hash) ? intelligence.deep_symbolize_keys : {}
      Ai::ProfileHistoryNarrativeBuilder.append_story_intelligence!(event, intelligence: payload)
    end
  rescue StandardError => e
    Rails.logger.warn("[AppendProfileHistoryNarrativeJob] failed for event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    nil
  end
end
