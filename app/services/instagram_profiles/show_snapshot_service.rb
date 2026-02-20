module InstagramProfiles
  class ShowSnapshotService
    AVAILABLE_TAGS = %w[personal_user friend female_friend male_friend relative page excluded automatic_reply].freeze

    def initialize(account:, profile:, mutual_limit: 36)
      @account = account
      @profile = profile
      @mutual_limit = mutual_limit.to_i
    end

    def call
      posts_scope = profile.instagram_profile_posts
      profile_posts_total_count = posts_scope.count
      deleted_posts_count = deleted_posts_count_for(posts_scope)
      analyzed_posts_count = posts_scope.where(ai_status: "analyzed").count

      behavior_profile = profile.instagram_profile_behavior_profile
      behavior_metadata = behavior_profile&.metadata
      behavior_metadata = {} unless behavior_metadata.is_a?(Hash)
      history_build_state = behavior_metadata["history_build"].is_a?(Hash) ? behavior_metadata["history_build"] : {}

      {
        profile_posts_total_count: profile_posts_total_count,
        deleted_posts_count: deleted_posts_count,
        active_posts_count: [profile_posts_total_count - deleted_posts_count, 0].max,
        analyzed_posts_count: analyzed_posts_count,
        pending_posts_count: [profile_posts_total_count - analyzed_posts_count, 0].max,
        messages_count: profile.instagram_messages.count,
        action_logs_count: profile.instagram_profile_action_logs.count,
        latest_analysis: profile.latest_analysis,
        latest_story_intelligence_event: latest_story_intelligence_event,
        available_tags: AVAILABLE_TAGS,
        history_build_state: history_build_state,
        history_ready: ActiveModel::Type::Boolean.new.cast(history_build_state["ready"]),
        mutual_profiles: MutualFriendsResolver.new(account: account, profile: profile).call(limit: mutual_limit)
      }
    end

    private

    attr_reader :account, :profile, :mutual_limit

    def deleted_posts_count_for(posts_scope)
      posts_scope
        .where.not(metadata: nil)
        .pluck(:metadata)
        .count { |metadata| ActiveModel::Type::Boolean.new.cast(metadata.is_a?(Hash) ? metadata["deleted_from_source"] : nil) }
    end

    def latest_story_intelligence_event
      profile.instagram_profile_events
        .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
        .order(detected_at: :desc, id: :desc)
        .limit(60)
        .detect do |event|
          metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
          story_intelligence_available_for_snapshot?(metadata: metadata)
        end
    end

    def story_intelligence_available_for_snapshot?(metadata:)
      intelligence = metadata["local_story_intelligence"].is_a?(Hash) ? metadata["local_story_intelligence"] : {}
      return true if intelligence.present?
      return true if metadata["ocr_text"].to_s.present?
      return true if Array(metadata["content_signals"]).any?
      return true if Array(metadata["object_detections"]).any?
      return true if Array(metadata["ocr_blocks"]).any?
      return true if Array(metadata["scenes"]).any?

      false
    end
  end
end
