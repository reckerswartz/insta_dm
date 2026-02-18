class SyncNextProfilesForAccountJob < ApplicationJob
  queue_as :profiles

  def perform(instagram_account_id:, limit: 10)
    account = InstagramAccount.find(instagram_account_id)
    cap = limit.to_i.clamp(1, 50)

    profiles = account.instagram_profiles
      .order(Arel.sql("COALESCE(last_synced_at, '1970-01-01') ASC, COALESCE(last_active_at, '1970-01-01') DESC, username ASC"))
      .limit(cap)

    profiles.each do |profile|
      log = profile.instagram_profile_action_logs.create!(
        instagram_account: account,
        action: "fetch_profile_details",
        status: "queued",
        trigger_source: "account_sync_next_profiles",
        occurred_at: Time.current,
        metadata: { requested_by: self.class.name, limit: cap }
      )

      job = FetchInstagramProfileDetailsJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: log.id
      )
      log.update!(active_job_id: job.job_id, queue_name: job.queue_name)
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "sync_next_profiles.profile_enqueue_failed",
        payload: {
          account_id: account.id,
          profile_id: profile.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
      next
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Queued profile sync for next #{profiles.size} profiles." }
    )
  end
end
