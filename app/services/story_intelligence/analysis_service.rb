# frozen_string_literal: true

require "base64"
require "digest"

module StoryIntelligence
  class AnalysisService
    MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024
    MAX_INLINE_VIDEO_BYTES = 10 * 1024 * 1024

    ANALYSIS_QUEUE_METADATA_KEYS = %w[
      status queued_at active_job_id queue_name downloaded_event_id instagram_story_id status_updated_at
      started_at completed_at failed_at failure_reason reply_queued reply_decision_reason
      ai_provider ai_model error_class error_message
    ].freeze

    def initialize(account:, profile:)
      @account = account
      @profile = profile
    end

    def analyze_story_for_comments(story:, analyzable:, bytes:, content_type:)
      media_payload = build_media_payload(story: story, bytes: bytes, content_type: content_type)
      payload = build_story_payload(story: story)

      run = Ai::Runner.new(account: account).analyze!(
        purpose: "post",
        analyzable: analyzable,
        payload: payload,
        media: media_payload,
        media_fingerprint: media_fingerprint_for_story(story: story, bytes: bytes, content_type: content_type)
      )

      analysis = run.dig(:result, :analysis)
      unless analysis.is_a?(Hash)
        return {
          ok: false,
          failure_reason: "analysis_payload_missing",
          error_class: "AnalysisPayloadMissingError",
          error_message: "AI analysis payload was missing or malformed."
        }
      end

      raw_metadata = analyzable.metadata.is_a?(Hash) ? analyzable.metadata : {}
      local_story_intelligence = analyzable.respond_to?(:local_story_intelligence_payload) ? analyzable.local_story_intelligence_payload : {}
      validated_story_insights = Ai::VerifiedStoryInsightBuilder.new(
        profile: profile,
        local_story_intelligence: local_story_intelligence,
        metadata: raw_metadata
      ).build
      generation_policy = validated_story_insights[:generation_policy].is_a?(Hash) ? validated_story_insights[:generation_policy] : {}
      ownership_classification = validated_story_insights[:ownership_classification].is_a?(Hash) ? validated_story_insights[:ownership_classification] : {}

      {
        ok: true,
        provider: run[:provider].key,
        model: run.dig(:result, :model),
        relevant: analysis["relevant"],
        author_type: analysis["author_type"],
        image_description: analysis["image_description"].to_s.presence,
        comment_suggestions: Array(analysis["comment_suggestions"]).first(8),
        generation_policy: generation_policy,
        ownership_classification: ownership_classification
      }
    rescue StandardError => e
      {
        ok: false,
        failure_reason: "analysis_error",
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 500)
      }
    end

    def story_reply_decision(analysis:, story_id:)
      return { queue: false, reason: "already_sent" } if story_reply_already_sent?(story_id: story_id)
      return { queue: false, reason: "already_queued" } if story_reply_already_queued?(story_id: story_id)
      return { queue: false, reason: "official_messaging_not_configured" } unless official_messaging_service.configured?

      relevant = analysis[:relevant]
      author_type = analysis[:author_type].to_s
      suggestions = Array(analysis[:comment_suggestions]).map(&:to_s).reject(&:blank?)
      generation_policy = analysis[:generation_policy].is_a?(Hash) ? analysis[:generation_policy] : {}

      return { queue: false, reason: "no_comment_suggestions" } if suggestions.empty?
      allow_comment_present = generation_policy.key?(:allow_comment) || generation_policy.key?("allow_comment")
      allow_comment_value = generation_policy[:allow_comment] || generation_policy["allow_comment"]
      if allow_comment_present && !ActiveModel::Type::Boolean.new.cast(allow_comment_value)
        return { queue: false, reason: generation_policy[:reason_code].to_s.presence || generation_policy["reason_code"].to_s.presence || "verified_policy_blocked" }
      end
      return { queue: false, reason: "not_relevant" } unless relevant == true

      allowed_types = %w[personal_user friend relative unknown]
      return { queue: false, reason: "author_type_#{author_type.presence || 'missing'}_not_allowed" } unless allowed_types.include?(author_type)

      { queue: true, reason: "eligible_for_reply" }
    end

    def queue_story_reply!(story_id:, analysis:, downloaded_event: nil, base_metadata: {})
      sid = story_id.to_s.strip
      return false if sid.blank?
      return false if story_reply_already_sent?(story_id: sid)
      return false if story_reply_already_queued?(story_id: sid)

      suggestion = select_unique_story_comment(
        suggestions: Array(analysis[:comment_suggestions]),
        analysis: analysis
      )
      return false if suggestion.blank?

      metadata = normalized_reply_metadata(base_metadata: base_metadata, suggestion: suggestion)
      enqueue_event = profile.record_event!(
        kind: "story_reply_queued",
        external_id: "story_reply_queued:#{sid}",
        occurred_at: Time.current,
        metadata: metadata.merge(
          delivery_status: "queued",
          queued_at: Time.current.iso8601(3)
        )
      )

      job = SendStoryReplyJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: sid,
        reply_text: suggestion,
        story_metadata: metadata,
        downloaded_event_id: downloaded_event&.id
      )

      enqueue_event.update!(
        metadata: enqueue_event.metadata.merge(
          "active_job_id" => job.job_id,
          "queue_name" => job.queue_name
        )
      )

      true
    rescue StandardError => e
      return false if e.is_a?(ActiveRecord::RecordNotUnique)

      account.instagram_messages.create!(
        instagram_profile: profile,
        direction: "outgoing",
        body: suggestion.to_s,
        status: "failed",
        error_message: "story_reply_enqueue_failed: #{e.message}"
      ) if suggestion.present?
      false
    end

    def normalized_story_payload(story_payload:, story_id:)
      raw = story_payload.is_a?(Hash) ? story_payload : {}
      normalized = raw.deep_symbolize_keys
      normalized[:story_id] = story_id
      normalized
    rescue StandardError
      { story_id: story_id.to_s }
    end

    private

    attr_reader :account, :profile

    def media_fingerprint_for_story(story:, bytes:, content_type:)
      return Digest::SHA256.hexdigest(bytes) if bytes.present?

      story_data = story.is_a?(Hash) ? story.with_indifferent_access : {}
      fallback = [
        story_data[:media_url].to_s,
        story_data[:image_url].to_s,
        story_data[:video_url].to_s,
        content_type.to_s
      ].find(&:present?)
      return nil if fallback.blank?

      Digest::SHA256.hexdigest(fallback)
    end

    def build_story_payload(story:)
      story_data = story.is_a?(Hash) ? story.with_indifferent_access : {}
      story_history = recent_story_history_context
      history_narrative = profile.history_narrative_text(max_chunks: 3)
      history_chunks = profile.history_narrative_chunks(max_chunks: 6)
      recent_post_context = profile.instagram_profile_posts.recent_first.limit(5).map do |post|
        {
          shortcode: post.shortcode,
          caption: post.caption.to_s,
          taken_at: post.taken_at&.iso8601,
          image_description: post.analysis.is_a?(Hash) ? post.analysis["image_description"] : nil,
          topics: post.analysis.is_a?(Hash) ? Array(post.analysis["topics"]).first(6) : []
        }
      end
      recent_event_context = profile.instagram_profile_events.order(detected_at: :desc).limit(20).pluck(:kind, :occurred_at).map do |kind, occurred_at|
        { kind: kind, occurred_at: occurred_at&.iso8601 }
      end

      {
        post: {
          shortcode: story_data[:story_id],
          caption: story_data[:caption],
          taken_at: normalized_timestamp(story_data[:taken_at]),
          permalink: story_data[:permalink],
          likes_count: nil,
          comments_count: nil,
          comments: []
        },
        author_profile: {
          username: profile.username,
          display_name: profile.display_name,
          bio: profile.bio,
          can_message: profile.can_message,
          tags: profile.profile_tags.pluck(:name).sort,
          recent_posts: recent_post_context,
          recent_profile_events: recent_event_context,
          recent_story_history: story_history,
          historical_narrative_text: history_narrative,
          historical_narrative_chunks: history_chunks
        },
        rules: {
          require_manual_review: true,
          style: "gen_z_light",
          context: "story_reply_suggestion",
          only_if_relevant: true,
          diversity_requirement: "Prefer novel comments and avoid repeating previous story replies."
        }
      }
    end

    def build_media_payload(story:, bytes:, content_type:)
      story_data = story.is_a?(Hash) ? story.with_indifferent_access : {}
      media_type = story_data[:media_type].to_s

      if media_type == "video"
        {
          type: "video",
          content_type: content_type,
          bytes: bytes.bytesize <= MAX_INLINE_VIDEO_BYTES ? bytes : nil
        }
      else
        payload = {
          type: "image",
          content_type: content_type,
          bytes: bytes
        }

        if bytes.bytesize <= MAX_INLINE_IMAGE_BYTES
          payload[:image_data_url] = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
        end

        payload
      end
    end

    def recent_story_history_context
      profile.instagram_profile_events
        .where(kind: [ "story_analyzed", "story_reply_sent", "story_comment_posted_via_feed" ])
        .order(detected_at: :desc, id: :desc)
        .limit(25)
        .map do |event|
          metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
          {
            kind: event.kind,
            occurred_at: event.occurred_at&.iso8601 || event.detected_at&.iso8601,
            story_id: metadata["story_id"].to_s.presence,
            image_description: metadata["ai_image_description"].to_s.presence,
            posted_comment: metadata["ai_reply_text"].to_s.presence || metadata["comment_text"].to_s.presence
          }.compact
        end
    end

    def story_reply_already_sent?(story_id:)
      profile.instagram_profile_events.where(kind: "story_reply_sent", external_id: "story_reply_sent:#{story_id}").exists?
    end

    def story_reply_already_queued?(story_id:)
      event = profile.instagram_profile_events.find_by(kind: "story_reply_queued", external_id: "story_reply_queued:#{story_id}")
      return false unless event

      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      status = metadata["delivery_status"].to_s
      return false if %w[sent failed].include?(status)

      event.detected_at.present? && event.detected_at > 12.hours.ago
    rescue StandardError
      false
    end

    def official_messaging_service
      @official_messaging_service ||= Messaging::IntegrationService.new
    end

    def normalized_reply_metadata(base_metadata:, suggestion:)
      metadata = base_metadata.is_a?(Hash) ? base_metadata.deep_dup : {}
      metadata = metadata.deep_stringify_keys
      metadata.except!(*ANALYSIS_QUEUE_METADATA_KEYS)
      metadata["ai_reply_text"] = suggestion
      metadata["auto_reply"] = true
      metadata
    rescue StandardError
      { "ai_reply_text" => suggestion.to_s, "auto_reply" => true }
    end

    def select_unique_story_comment(suggestions:, analysis: nil)
      candidates = Array(suggestions).map(&:to_s).map(&:strip).reject(&:blank?)
      return nil if candidates.empty?

      history = profile.instagram_profile_events
        .where(kind: [ "story_reply_sent", "story_comment_posted_via_feed" ])
        .order(detected_at: :desc, id: :desc)
        .limit(40)
        .map { |event| event.metadata.is_a?(Hash) ? (event.metadata["ai_reply_text"].to_s.presence || event.metadata["comment_text"].to_s) : "" }
        .reject(&:blank?)

      analysis_hash = analysis.is_a?(Hash) ? analysis : {}
      context_keywords = []
      context_keywords.concat(Array(analysis_hash[:topics] || analysis_hash["topics"]).map(&:to_s))
      context_keywords.concat(Array(analysis_hash[:image_description] || analysis_hash["image_description"]).map(&:to_s))
      engine = Ai::CommentPolicyEngine.new
      filtered = engine.evaluate(
        suggestions: candidates,
        historical_comments: history,
        context_keywords: context_keywords,
        max_suggestions: 8,
        channel: "story",
        require_direct_address: true
      )[:accepted]
      candidates = Array(filtered).presence || candidates

      return candidates.first if history.empty?

      ranked = candidates.sort_by do |candidate|
        history.map { |past| text_similarity(candidate, past) }.max.to_f
      end
      ranked.find { |candidate| history.all? { |past| text_similarity(candidate, past) < 0.72 } } || ranked.first
    end

    def text_similarity(left_text, right_text)
      left = tokenize(left_text)
      right = tokenize(right_text)
      return 0.0 if left.empty? || right.empty?

      overlap = (left & right).length.to_f
      overlap / [ left.length, right.length ].max.to_f
    end

    def tokenize(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).uniq
    end

    def normalized_timestamp(value)
      return value.iso8601 if value.respond_to?(:iso8601)
      return value.to_s if value.present?

      nil
    rescue StandardError
      nil
    end
  end
end
