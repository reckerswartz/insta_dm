class DownloadMissingAvatarsJob < ApplicationJob
  queue_as :avatars

  def perform(instagram_account_id:, limit: 250)
    account = InstagramAccount.find(instagram_account_id)

    limit = limit.to_i.clamp(1, 2_000)
    profiles = account.instagram_profiles
      .where.not(profile_pic_url: [nil, ""])
      .left_joins(:avatar_attachment)
      .where(active_storage_attachments: { id: nil })
      .limit(limit)

    downloaded = 0
    failed = 0

    profiles.each do |profile|
      begin
        DownloadInstagramProfileAvatarJob.perform_now(instagram_account_id: account.id, instagram_profile_id: profile.id, broadcast: false)
        downloaded += 1
      rescue StandardError
        failed += 1
      end
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Avatar sync complete: downloaded #{downloaded}, failed #{failed}." }
    )
  rescue StandardError => e
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Avatar sync failed: #{e.message}" }
    )
    raise
  end
end
