module Instagram
  class MediaDownloadTrustPolicy
    TRUSTED_PROFILE_TAGS = %w[
      personal_user
      friend
      female_friend
      male_friend
      relative
    ].freeze

    class << self
      def evaluate(account:, profile:, media_url:)
        relationship = relationship_context(account: account, profile: profile)
        return relationship_block_context(reason: relationship[:reason]) unless relationship[:allowed]

        source_blocked = blocked_source_context(url: media_url)
        return source_blocked if source_blocked.present?

        { blocked: false }
      rescue StandardError
        { blocked: false }
      end

      def blocked_source_context(url:)
        context = Instagram::Client::MediaSourcePolicy.blocked_source_context(url: url)
        return nil if context.blank?

        context.merge(blocked: true)
      rescue StandardError
        nil
      end

      private

      def relationship_context(account:, profile:)
        return { allowed: false, reason: "profile_missing" } unless profile
        return { allowed: true, reason: "self_profile" } if self_profile?(account: account, profile: profile)
        return { allowed: true, reason: "follow_graph_connected" } if follow_graph_connected?(profile: profile)
        return { allowed: true, reason: "trusted_profile_tag" } if trusted_profile_tag?(profile: profile)
        return { allowed: true, reason: "relationship_gate_disabled" } unless require_profile_connection?

        { allowed: false, reason: "not_followed_or_connected" }
      rescue StandardError
        { allowed: false, reason: "relationship_check_failed" }
      end

      def self_profile?(account:, profile:)
        profile_username = normalize_username(profile&.username)
        account_username = normalize_username(account&.username)
        profile_username.present? && profile_username == account_username
      end

      def follow_graph_connected?(profile:)
        ActiveModel::Type::Boolean.new.cast(profile.following) ||
          ActiveModel::Type::Boolean.new.cast(profile.follows_you)
      end

      def trusted_profile_tag?(profile:)
        names =
          if profile.association(:profile_tags).loaded?
            profile.profile_tags.map { |tag| tag.name.to_s.strip.downcase }
          else
            profile.profile_tags.pluck(:name).map { |value| value.to_s.strip.downcase }
          end
        names.any? { |name| TRUSTED_PROFILE_TAGS.include?(name) }
      rescue StandardError
        false
      end

      def require_profile_connection?
        ActiveModel::Type::Boolean.new.cast(
          ENV.fetch("MEDIA_DOWNLOAD_REQUIRE_PROFILE_CONNECTION", "true")
        )
      rescue StandardError
        true
      end

      def normalize_username(value)
        value.to_s.strip.downcase
      end

      def relationship_block_context(reason:)
        {
          blocked: true,
          reason_code: "profile_not_connected",
          marker: reason.to_s.presence || "unknown_relationship_state",
          confidence: "high",
          source: "relationship"
        }
      end
    end
  end
end
