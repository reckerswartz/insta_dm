class ValidateStoryReplyEligibilityJob < ApplicationJob
  queue_as :story_validation

  DEFAULT_RETRY_DAYS = 3

  def perform(instagram_account_id:, instagram_profile_id:, story_username:, story_id:, api_reply_gate: nil)
    account = InstagramAccount.find_by(id: instagram_account_id)
    profile = InstagramProfile.find_by(id: instagram_profile_id, instagram_account_id: instagram_account_id)
    return missing_context_result unless account && profile

    normalized_story_id = story_id.to_s.strip
    return invalid_input_result(reason_code: "missing_story_id", status: "Story id missing") if normalized_story_id.blank?

    normalized_username = story_username.to_s.strip
    normalized_username = profile.username.to_s.strip if normalized_username.blank?
    return invalid_input_result(reason_code: "missing_story_username", status: "Story username missing") if normalized_username.blank?

    retry_after_at = profile.story_interaction_retry_after_at
    if interaction_retry_pending?(profile: profile, retry_after_at: retry_after_at)
      return {
        eligible: false,
        reason_code: "interaction_retry_window_active",
        status: "Interaction unavailable (retry pending)",
        retry_after_at: retry_after_at&.iso8601,
        interaction_retry_active: true,
        interaction_state: profile.story_interaction_state.to_s,
        interaction_reason: profile.story_interaction_reason.to_s,
        api_reply_gate: { known: false, reply_possible: nil, reason_code: nil, status: "Unknown" }
      }
    end

    gate =
      if api_reply_gate.is_a?(Hash) && (api_reply_gate.key?(:known) || api_reply_gate.key?("known"))
        normalize_gate(api_reply_gate)
      else
        fetch_api_reply_gate(account: account, username: normalized_username, story_id: normalized_story_id)
      end

    if gate[:known] && gate[:reply_possible] == false
      retry_after = Time.current + retry_days.days
      profile.update!(
        story_interaction_state: "unavailable",
        story_interaction_reason: gate[:reason_code].to_s.presence || "api_can_reply_false",
        story_interaction_checked_at: Time.current,
        story_interaction_retry_after_at: retry_after,
        story_reaction_available: false
      )

      return {
        eligible: false,
        reason_code: gate[:reason_code].to_s.presence || "api_can_reply_false",
        status: gate[:status].to_s.presence || "Replies not allowed (API)",
        retry_after_at: retry_after.iso8601,
        interaction_retry_active: false,
        interaction_state: "unavailable",
        interaction_reason: gate[:reason_code].to_s.presence || "api_can_reply_false",
        api_reply_gate: gate
      }
    end

    if gate[:known] && gate[:reply_possible] == true
      profile.update!(
        story_interaction_state: "reply_available",
        story_interaction_reason: gate[:reason_code].to_s.presence || "api_can_reply_true",
        story_interaction_checked_at: Time.current,
        story_interaction_retry_after_at: nil,
        story_reaction_available: true
      )
    else
      profile.update!(
        story_interaction_checked_at: Time.current
      )
    end

    {
      eligible: true,
      reason_code: nil,
      status: gate[:status].to_s.presence || "Eligible",
      retry_after_at: nil,
      interaction_retry_active: false,
      interaction_state: profile.story_interaction_state.to_s,
      interaction_reason: profile.story_interaction_reason.to_s,
      api_reply_gate: gate
    }
  rescue StandardError => e
    {
      eligible: true,
      reason_code: nil,
      status: "Eligibility fallback (error)",
      retry_after_at: nil,
      interaction_retry_active: false,
      interaction_state: nil,
      interaction_reason: nil,
      api_reply_gate: {
        known: false,
        reply_possible: nil,
        reason_code: "validation_error:#{e.class.name}",
        status: "Unknown"
      }
    }
  end

  private

  def missing_context_result
    {
      eligible: false,
      reason_code: "missing_context",
      status: "Profile context missing",
      retry_after_at: nil,
      interaction_retry_active: false,
      interaction_state: nil,
      interaction_reason: nil,
      api_reply_gate: { known: false, reply_possible: nil, reason_code: nil, status: "Unknown" }
    }
  end

  def invalid_input_result(reason_code:, status:)
    {
      eligible: false,
      reason_code: reason_code,
      status: status,
      retry_after_at: nil,
      interaction_retry_active: false,
      interaction_state: nil,
      interaction_reason: nil,
      api_reply_gate: { known: false, reply_possible: nil, reason_code: nil, status: "Unknown" }
    }
  end

  def interaction_retry_pending?(profile:, retry_after_at:)
    profile.story_interaction_state.to_s == "unavailable" &&
      retry_after_at.present? &&
      retry_after_at > Time.current
  end

  def fetch_api_reply_gate(account:, username:, story_id:)
    client = Instagram::Client.new(account: account)
    payload = client.send(:story_reply_capability_from_api, username: username, story_id: story_id, cache: {})
    normalize_gate(payload)
  rescue StandardError
    { known: false, reply_possible: nil, reason_code: "api_capability_error", status: "Unknown" }
  end

  def normalize_gate(payload)
    raw = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
    {
      known: ActiveModel::Type::Boolean.new.cast(raw[:known]),
      reply_possible: raw.key?(:reply_possible) ? ActiveModel::Type::Boolean.new.cast(raw[:reply_possible]) : nil,
      reason_code: raw[:reason_code].to_s.presence,
      status: raw[:status].to_s.presence || "Unknown"
    }
  end

  def retry_days
    client_days = Instagram::Client::STORY_INTERACTION_RETRY_DAYS if defined?(Instagram::Client::STORY_INTERACTION_RETRY_DAYS)
    days = client_days.to_i
    days.positive? ? days : DEFAULT_RETRY_DAYS
  rescue StandardError
    DEFAULT_RETRY_DAYS
  end
end
