require "base64"
require "digest"
require "uri"

class AnalyzeInstagramProfilePostJob < ApplicationJob
  queue_as :ai

  MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision

    if policy_decision[:skip_post_analysis]
      if policy_decision[:reason_code].to_s == "non_personal_profile_page" || policy_decision[:reason_code].to_s == "scan_excluded_tag"
        Instagram::ProfileScanPolicy.mark_scan_excluded!(profile: profile)
      end

      Instagram::ProfileScanPolicy.mark_post_analysis_skipped!(post: post, decision: policy_decision)
      return
    end

    payload = build_payload(profile: profile, post: post)
    media = build_media_payload(post)

    run = Ai::Runner.new(account: account).analyze!(
      purpose: "post",
      analyzable: post,
      payload: payload,
      media: media,
      media_fingerprint: media_fingerprint_for(post: post, media: media)
    )

    post.update!(
      ai_status: "analyzed",
      analyzed_at: Time.current,
      ai_provider: run[:provider].key,
      ai_model: run.dig(:result, :model),
      analysis: run.dig(:result, :analysis)
    )
    PostFaceRecognitionService.new.process!(post: post)
    Ai::ProfileAutoTagger.sync_from_post_analysis!(profile: profile, analysis: run.dig(:result, :analysis))

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Profile post analyzed: #{post.shortcode}." }
    )
  rescue StandardError => e
    post&.update!(ai_status: "failed") if defined?(post) && post&.persisted?

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Profile post analysis failed: #{e.message}" }
    ) if defined?(account) && account

    raise
  end

  private

  def build_payload(profile:, post:)
    {
      post: {
        shortcode: post.shortcode,
        caption: post.caption,
        taken_at: post.taken_at&.iso8601,
        permalink: post.permalink_url,
        likes_count: post.likes_count,
        comments_count: post.comments_count,
        comments: post.instagram_profile_post_comments.recent_first.limit(25).map do |c|
          {
            author_username: c.author_username,
            body: c.body,
            commented_at: c.commented_at&.iso8601
          }
        end
      },
      author_profile: {
        username: profile.username,
        display_name: profile.display_name,
        bio: profile.bio,
        can_message: profile.can_message,
        tags: profile.profile_tags.pluck(:name).sort
      },
      rules: {
        require_manual_review: true,
        style: "gen_z_light"
      }
    }
  end

  def build_media_payload(post)
    return { type: "none" } unless post.media.attached?

    blob = post.media.blob
    return { type: "none" } unless blob
    return { type: "none" } unless blob.content_type.to_s.start_with?("image/")

    if blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES
      return { type: "image", content_type: blob.content_type, url: post.source_media_url.to_s }
    end

    data = blob.download
    encoded = Base64.strict_encode64(data)

    {
      type: "image",
      content_type: blob.content_type,
      bytes: data,
      image_data_url: "data:#{blob.content_type};base64,#{encoded}"
    }
  rescue StandardError
    { type: "none" }
  end

  def media_fingerprint_for(post:, media:)
    return post.media_url_fingerprint.to_s if post.media_url_fingerprint.to_s.present?

    if post.media.attached?
      checksum = post.media.blob&.checksum.to_s
      return "blob:#{checksum}" if checksum.present?
    end

    normalized_url = normalize_url(post.source_media_url)
    return Digest::SHA256.hexdigest(normalized_url) if normalized_url.present?

    bytes = media[:bytes]
    return Digest::SHA256.hexdigest(bytes) if bytes.present?

    nil
  end

  def normalize_url(raw)
    value = raw.to_s.strip
    return nil if value.blank?

    uri = URI.parse(value)
    return value unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue StandardError
    value
  end
end
