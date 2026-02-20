class AppendProfileHistoryNarrativeJob < ApplicationJob
  queue_as :maintenance
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(instagram_profile_event_id:, mode: "event", intelligence: nil)
    event = InstagramProfileEvent.find(instagram_profile_event_id)

    case mode.to_s
    when "event"
      Ai::ProfileHistoryNarrativeBuilder.append_event!(event)
    when "story_intelligence"
      payload = intelligence.is_a?(Hash) ? intelligence.deep_symbolize_keys : {}
      Ai::ProfileHistoryNarrativeBuilder.append_story_intelligence!(event, intelligence: payload)
    else
      Ops::StructuredLogger.warn(
        event: "profile_history_narrative.unknown_mode",
        payload: { instagram_profile_event_id: event.id, mode: mode.to_s }
      )
    end
  end
end
