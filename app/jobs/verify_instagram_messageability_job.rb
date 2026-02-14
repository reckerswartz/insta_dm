class VerifyInstagramMessageabilityJob < ApplicationJob
  queue_as :profiles

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: "verify_messageability",
      profile_action_log_id: profile_action_log_id
    )
    action_log.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id })

    result = Instagram::Client.new(account: account).verify_messageability!(username: profile.username)
    profile.update!(
      can_message: result[:can_message],
      restriction_reason: result[:restriction_reason],
      dm_interaction_state: result[:dm_state].to_s.presence || (result[:can_message] ? "messageable" : "unavailable"),
      dm_interaction_reason: result[:dm_reason].to_s.presence || result[:restriction_reason].to_s,
      dm_interaction_checked_at: Time.current,
      dm_interaction_retry_after_at: result[:dm_retry_after_at]
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Messageability for #{profile.username}: #{result[:can_message] ? 'Yes' : 'No'}." }
    )
    action_log.mark_succeeded!(
      extra_metadata: result,
      log_text: "Messageability result: #{result[:can_message] ? 'Yes' : 'No'}"
    )
  rescue StandardError => e
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Messageability check failed: #{e.message}" }
    )
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, action:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: action,
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end
end
