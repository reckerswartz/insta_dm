class AnalyzeInstagramPostJob < ApplicationJob
  require "base64"
  require "digest"
  require "uri"

  queue_as :ai

  MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024
  MAX_INLINE_VIDEO_BYTES = 10 * 1024 * 1024

  def perform(instagram_post_id:)
    post = InstagramPost.find(instagram_post_id)
    account = post.instagram_account

    # Resolve an existing profile record for tag rules, if available.
    if post.instagram_profile_id.nil? && post.author_username.to_s.strip.present?
      post.instagram_profile = account.instagram_profiles.find_by(username: post.author_username)
      post.save! if post.changed?
    end

    payload = build_payload(post)
    media = build_media_payload(post)
    run = Ai::Runner.new(account: account).analyze!(
      purpose: "post",
      analyzable: post,
      payload: payload,
      media: media,
      media_fingerprint: media_fingerprint_for(post: post, media: media)
    )
    result = run[:result]

    post.update!(
      status: "analyzed",
      analyzed_at: Time.current,
      ai_provider: run[:provider].key,
      ai_model: result[:model],
      analysis: result[:analysis]
    )

    relevant = ActiveModel::Type::Boolean.new.cast(post.analysis&.dig("relevant"))
    unless relevant
      post.update!(status: "ignored", purge_at: 24.hours.from_now)
    end

    # Trigger profile re-evaluation after post analysis
    if post.instagram_profile.present?
      ProfileReevaluationService.new(account: account, profile: post.instagram_profile)
        .reevaluate_after_content_scan!(content_type: "post", content_id: post.id)
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Post analyzed via #{run[:provider].display_name}: #{post.shortcode} (#{relevant ? 'relevant' : 'ignored'})." }
    )
  rescue StandardError => e
    post ||= InstagramPost.where(id: instagram_post_id).first
    account ||= post&.instagram_account

    post&.update!(status: "pending") # allow retry

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Post analysis failed: #{e.message}" }
    ) if account

    raise
  end

  private

  def build_payload(post)
    profile = post.instagram_profile

    {
      post: {
        shortcode: post.shortcode,
        kind: post.post_kind,
        author_username: post.author_username,
        caption: post.caption,
        taken_at: post.taken_at&.iso8601,
        detected_at: post.detected_at&.iso8601,
        permalink: post.permalink
      },
      author_profile: profile ? {
        username: profile.username,
        display_name: profile.display_name,
        bio: profile.bio,
        tags: profile.profile_tags.pluck(:name).sort,
        following: profile.following,
        follows_you: profile.follows_you,
        mutual: profile.mutual?
      } : nil,
      rules: {
        # Basic tag-based gates. The AI should treat these as hard preferences.
        ignore_if_tagged: %w[relative page excluded],
        prefer_interact_if_tagged: %w[female_friend male_friend friend personal_user],
        require_manual_review: true
      }
    }
  end

  def build_media_payload(post)
    return { type: "none" } unless post.media.attached?

    blob = post.media.blob
    return { type: "none" } unless blob

    content_type = blob.content_type.to_s
    return { type: "none", content_type: content_type } if blob.byte_size.to_i <= 0

    if content_type.start_with?("image/")
      return { type: "image", content_type: content_type } if blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES

      data = blob.download
      encoded = Base64.strict_encode64(data)

      return {
        type: "image",
        content_type: content_type,
        bytes: data,
        image_data_url: "data:#{content_type};base64,#{encoded}"
      }
    end

    if content_type.start_with?("video/")
      return { type: "none", content_type: content_type, media_skipped_reason: "video_too_large" } if blob.byte_size.to_i > MAX_INLINE_VIDEO_BYTES

      return {
        type: "video",
        content_type: content_type,
        reference_id: "instagram_post_#{post.id}",
        bytes: blob.download
      }
    end

    { type: "none", content_type: content_type }
  rescue StandardError
    { type: "none" }
  end

  def media_fingerprint_for(post:, media:)
    if post.media.attached?
      checksum = post.media.blob&.checksum.to_s
      return "blob:#{checksum}" if checksum.present?
    end

    normalized_url = normalize_url(post.media_url)
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
