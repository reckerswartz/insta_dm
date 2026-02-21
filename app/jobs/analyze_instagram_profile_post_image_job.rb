class AnalyzeInstagramProfilePostImageJob < ApplicationJob
  queue_as :ai_visual_queue

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, source_job: nil)
    account = InstagramAccount.find_by(id: instagram_account_id)
    return unless account

    profile = account.instagram_profiles.find_by(id: instagram_profile_id)
    return unless profile

    post = profile.instagram_profile_posts.find_by(id: instagram_profile_post_id)
    return unless post

    stamp_state!(post: post, status: "running", source_job: source_job)

    Ai::ProfilePostImageDescriptionService.new(
      account: account,
      profile: profile,
      post: post
    ).run!

    stamp_state!(post: post, status: "completed", source_job: source_job)
  rescue StandardError => e
    stamp_state!(
      post: post,
      status: "failed",
      source_job: source_job,
      error_class: e.class.name,
      error_message: e.message.to_s.byteslice(0, 280)
    ) if defined?(post) && post&.persisted?
    raise
  end

  private

  def stamp_state!(post:, status:, source_job:, error_class: nil, error_message: nil)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["profile_image_description"].is_a?(Hash) ? metadata["profile_image_description"].deep_dup : {}
      now = Time.current

      state["status"] = status.to_s
      state["source_job"] = source_job.to_s.presence || state["source_job"].to_s.presence || self.class.name
      state["updated_at"] = now.iso8601(3)
      state["started_at"] = now.iso8601(3) if status.to_s == "running"
      state["completed_at"] = now.iso8601(3) if status.to_s == "completed"
      if status.to_s == "failed"
        state["failed_at"] = now.iso8601(3)
        state["error_class"] = error_class.to_s.presence
        state["error_message"] = error_message.to_s.presence
      else
        state["error_class"] = nil
        state["error_message"] = nil
      end

      metadata["profile_image_description"] = state
      post.update!(metadata: metadata)
    end
  rescue StandardError
    nil
  end
end
