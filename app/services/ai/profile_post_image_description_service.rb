require "base64"
require "digest"

module Ai
  class ProfilePostImageDescriptionService
    MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024

    def initialize(account:, profile:, post:)
      @account = account
      @profile = profile
      @post = post
    end

    def run!
      analysis_data = run_post_image_description!
      persist_post_analysis!(analysis_data: analysis_data)
      refresh_post_signals!
      analysis_data
    end

    private

    attr_reader :account, :profile, :post

    def run_post_image_description!
      history_narrative = profile.history_narrative_text(max_chunks: 3)
      history_chunks = profile.history_narrative_chunks(max_chunks: 6)

      payload = {
        post: {
          shortcode: post.shortcode,
          caption: post.caption,
          taken_at: post.taken_at&.iso8601,
          permalink: post.permalink_url,
          likes_count: post.likes_count,
          comments_count: post.comments_count,
          comments: post.instagram_profile_post_comments.recent_first.limit(25).map do |comment|
            {
              author_username: comment.author_username,
              body: comment.body,
              commented_at: comment.commented_at&.iso8601
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
          style: "gen_z_light",
          historical_narrative_text: history_narrative,
          historical_narrative_chunks: history_chunks
        }
      }

      run = Ai::Runner.new(account: account).analyze!(
        purpose: "post",
        analyzable: post,
        payload: payload,
        media: build_post_media_payload,
        media_fingerprint: media_fingerprint
      )

      {
        "provider" => run[:provider].key,
        "model" => run.dig(:result, :model),
        "analysis" => run.dig(:result, :analysis)
      }
    end

    def persist_post_analysis!(analysis_data:)
      analysis = analysis_data["analysis"].is_a?(Hash) ? analysis_data["analysis"] : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      metadata["analysis_input"] = {
        "shortcode" => post.shortcode,
        "taken_at" => post.taken_at&.iso8601,
        "caption" => post.caption.to_s,
        "image_description" => analysis["image_description"],
        "topics" => Array(analysis["topics"]).first(10),
        "comment_suggestions" => Array(analysis["comment_suggestions"]).first(5)
      }

      post.update!(
        ai_status: "analyzed",
        analyzed_at: Time.current,
        ai_provider: analysis_data["provider"],
        ai_model: analysis_data["model"],
        analysis: analysis,
        metadata: metadata
      )
    end

    def refresh_post_signals!
      begin
        PostFaceRecognitionService.new.process!(post: post)
      rescue StandardError
        nil
      end

      begin
        analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
        Ai::ProfileAutoTagger.sync_from_post_analysis!(profile: profile, analysis: analysis)
      rescue StandardError
        nil
      end
    end

    def build_post_media_payload
      return { type: "none" } unless post.media.attached?

      blob = post.media.blob
      return { type: "none" } unless blob&.content_type.to_s.start_with?("image/")

      if blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES
        return { type: "image", content_type: blob.content_type, url: post.source_media_url.to_s }
      end

      data = blob.download
      {
        type: "image",
        content_type: blob.content_type,
        bytes: data,
        image_data_url: "data:#{blob.content_type};base64,#{Base64.strict_encode64(data)}"
      }
    rescue StandardError
      { type: "none" }
    end

    def media_fingerprint
      return post.media_url_fingerprint.to_s if post.media_url_fingerprint.to_s.present?

      if post.media.attached?
        checksum = post.media.blob&.checksum.to_s
        return "blob:#{checksum}" if checksum.present?
      end

      url = post.source_media_url.to_s
      return Digest::SHA256.hexdigest(url) if url.present?

      nil
    end
  end
end
