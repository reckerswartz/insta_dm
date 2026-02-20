require "timeout"

class RefreshProfilePostFaceIdentityJob < ApplicationJob
  queue_as :ai_face_queue

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, trigger_source: "profile_history_build")
    account = InstagramAccount.find_by(id: instagram_account_id)
    return unless account

    profile = account.instagram_profiles.find_by(id: instagram_profile_id)
    return unless profile

    post = profile.instagram_profile_posts.find_by(id: instagram_profile_post_id)
    return unless post && post.media.attached?

    mark_face_refresh_state!(
      post: post,
      attributes: {
        "status" => "running",
        "started_at" => Time.current.iso8601(3),
        "trigger_source" => trigger_source.to_s.presence || "profile_history_build",
        "active_job_id" => job_id,
        "queue_name" => queue_name
      }
    )

    result = Timeout.timeout(face_refresh_timeout_seconds) do
      PostFaceRecognitionService.new.process!(post: post)
    end

    mark_face_refresh_state!(
      post: post,
      attributes: {
        "status" => "completed",
        "finished_at" => Time.current.iso8601(3),
        "result" => {
          "skipped" => ActiveModel::Type::Boolean.new.cast(result[:skipped]),
          "reason" => result[:reason].to_s.presence,
          "face_count" => result[:face_count].to_i,
          "linked_face_count" => result[:linked_face_count].to_i,
          "low_confidence_filtered_count" => result[:low_confidence_filtered_count].to_i,
          "matched_people_count" => Array(result[:matched_people]).length
        }.compact
      }
    )
  rescue StandardError => e
    if defined?(post) && post&.persisted?
      mark_face_refresh_state!(
        post: post,
        attributes: {
          "status" => "failed",
          "failed_at" => Time.current.iso8601(3),
          "error_class" => e.class.name,
          "error_message" => e.message.to_s.byteslice(0, 280)
        }
      )
    end
    raise
  end

  private

  def face_refresh_timeout_seconds
    ENV.fetch("PROFILE_HISTORY_FACE_REFRESH_TIMEOUT_SECONDS", "180").to_i.clamp(20, 420)
  end

  def mark_face_refresh_state!(post:, attributes:)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      history = metadata["history_build"].is_a?(Hash) ? metadata["history_build"].deep_dup : {}
      state = history["face_refresh"].is_a?(Hash) ? history["face_refresh"].deep_dup : {}
      state.merge!(attributes.to_h.compact)
      history["face_refresh"] = state
      history["updated_at"] = Time.current.iso8601(3)
      metadata["history_build"] = history
      post.update!(metadata: metadata)
    end
  rescue StandardError
    nil
  end
end
