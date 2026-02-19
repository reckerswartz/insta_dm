module Instagram
  class ProfileScanPolicy
    DEFAULT_MAX_FOLLOWERS = 20_000
    EXCLUDED_SCAN_TAG = "profile_scan_excluded".freeze
    PERSONAL_OVERRIDE_TAGS = %w[personal_user friend female_friend male_friend relative].freeze

    NON_PERSONAL_PAGE_KEYWORDS = %w[
      meme memes
      quote quotes
      facts fact
      news updates
      media entertainment
      viral humor funny
      giveaway deals
      shop store brand
      fanpage
    ].freeze

    def self.max_followers_threshold
      configured = Rails.application.config.x.instagram.profile_scan_max_followers
      value = parse_integer(configured)
      return value if value.to_i.positive?

      DEFAULT_MAX_FOLLOWERS
    end

    def self.skip_from_cached_profile?(profile:)
      decision = new(profile: profile).decision
      ActiveModel::Type::Boolean.new.cast(decision[:skip_scan])
    rescue StandardError
      false
    end

    def self.build_skip_post_analysis_payload(decision:)
      data = decision.is_a?(Hash) ? decision : {}
      {
        "skipped" => true,
        "policy" => "profile_scan_policy_v1",
        "reason_code" => data[:reason_code].to_s.presence || data["reason_code"].to_s.presence || "scan_policy_blocked",
        "reason" => data[:reason].to_s.presence || data["reason"].to_s.presence || "Post analysis skipped by profile scan policy.",
        "followers_count" => parse_integer(data[:followers_count] || data["followers_count"]),
        "max_allowed_followers" => parse_integer(data[:max_followers] || data["max_followers"]) || max_followers_threshold,
        "decided_at" => Time.current.iso8601
      }.compact
    end

    def self.mark_post_analysis_skipped!(post:, decision:)
      payload = build_skip_post_analysis_payload(decision: decision)
      existing = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      post.update!(
        ai_status: "analyzed",
        analyzed_at: Time.current,
        ai_provider: "policy",
        ai_model: "profile_scan_policy_v1",
        analysis: existing.merge(payload)
      )
    end

    def self.mark_scan_excluded!(profile:)
      tag = ProfileTag.find_or_create_by!(name: EXCLUDED_SCAN_TAG)
      return if profile.profile_tags.exists?(id: tag.id)

      profile.profile_tags << tag
    end

    def self.clear_scan_excluded!(profile:)
      tag = ProfileTag.find_by(name: EXCLUDED_SCAN_TAG)
      return unless tag

      profile.profile_tags.destroy(tag) if profile.profile_tags.exists?(id: tag.id)
    end

    def initialize(profile:, profile_details: nil, max_followers: nil)
      @profile = profile
      @profile_details = profile_details.is_a?(Hash) ? profile_details.deep_symbolize_keys : {}
      @max_followers = self.class.parse_integer(max_followers) || self.class.max_followers_threshold
    end

    def decision
      @decision ||= evaluate
    end

    private

    def evaluate
      followers_count = resolved_followers_count
      if followers_count.to_i.positive? && followers_count > @max_followers.to_i
        return build_decision(
          skip_scan: true,
          skip_post_analysis: true,
          reason_code: "followers_threshold_exceeded",
          reason: "followers_count #{followers_count} exceeds max allowed #{@max_followers}.",
          followers_count: followers_count,
          max_followers: @max_followers
        )
      end

      if scan_excluded_tagged?
        return build_decision(
          skip_scan: true,
          skip_post_analysis: true,
          reason_code: "scan_excluded_tag",
          reason: "Profile tagged as scan-excluded.",
          followers_count: followers_count,
          max_followers: @max_followers
        )
      end

      if non_personal_page?
        return build_decision(
          skip_scan: true,
          skip_post_analysis: true,
          reason_code: "non_personal_profile_page",
          reason: "Profile appears to be a non-personal page (meme/news/info style).",
          followers_count: followers_count,
          max_followers: @max_followers
        )
      end

      build_decision(
        skip_scan: false,
        skip_post_analysis: false,
        reason_code: "scan_allowed",
        reason: "Profile eligible for scan and post analysis.",
        followers_count: followers_count,
        max_followers: @max_followers
      )
    end

    def build_decision(skip_scan:, skip_post_analysis:, reason_code:, reason:, followers_count:, max_followers:)
      {
        skip_scan: ActiveModel::Type::Boolean.new.cast(skip_scan),
        skip_post_analysis: ActiveModel::Type::Boolean.new.cast(skip_post_analysis),
        reason_code: reason_code.to_s,
        reason: reason.to_s,
        followers_count: followers_count,
        max_followers: max_followers.to_i
      }
    end

    def resolved_followers_count
      from_details = self.class.parse_integer(@profile_details[:followers_count])
      return from_details if from_details.to_i.positive?

      from_profile = self.class.parse_integer(@profile&.followers_count)
      return from_profile if from_profile.to_i.positive?

      0
    end

    def scan_excluded_tagged?
      profile_tag_names.include?(EXCLUDED_SCAN_TAG)
    end

    def non_personal_page?
      return false if personal_override_tagged?

      combined = [
        @profile&.username,
        @profile&.display_name,
        @profile&.bio,
        @profile_details[:username],
        @profile_details[:display_name],
        @profile_details[:bio],
        @profile_details[:category_name]
      ].map(&:to_s).join(" ").downcase
      return false if combined.blank?

      keyword_hits = NON_PERSONAL_PAGE_KEYWORDS.count { |keyword| combined.include?(keyword) }
      business = ActiveModel::Type::Boolean.new.cast(@profile_details[:is_business_account])
      category = @profile_details[:category_name].to_s.downcase

      return true if business && category.match?(/\b(media|news|entertainment|publisher|brand|store|shop)\b/)
      return true if keyword_hits >= 2
      return true if keyword_hits.positive? && business

      false
    end

    def personal_override_tagged?
      profile_tag_names.any? { |name| PERSONAL_OVERRIDE_TAGS.include?(name) }
    end

    def profile_tag_names
      @profile_tag_names ||= begin
        return [] unless @profile

        if @profile.association(:profile_tags).loaded?
          @profile.profile_tags.map { |tag| tag.name.to_s }
        else
          @profile.profile_tags.pluck(:name)
        end
      end
    rescue StandardError
      []
    end

    def self.parse_integer(value)
      return nil if value.nil?

      text = value.to_s.strip
      return nil if text.blank?
      return nil unless text.match?(/\A-?\d+\z/)

      text.to_i
    rescue StandardError
      nil
    end
  end
end
