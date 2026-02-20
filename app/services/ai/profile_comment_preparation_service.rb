module Ai
  class ProfileCommentPreparationService
    DEFAULT_POSTS_LIMIT = 10
    DEFAULT_COMMENTS_LIMIT = 12
    MAX_POSTS_LIMIT = 20
    MIN_REQUIRED_ANALYZED_POSTS = 3
    CACHE_TTL = 30.minutes
    PREPARATION_VERSION = "profile_comment_preparation_v1".freeze

    def initialize(
      account:,
      profile:,
      posts_limit: DEFAULT_POSTS_LIMIT,
      comments_limit: DEFAULT_COMMENTS_LIMIT,
      analyze_missing_posts: true,
      collector: nil,
      post_analyzer: nil,
      user_profile_builder_service: UserProfileBuilderService.new,
      face_identity_resolution_service: FaceIdentityResolutionService.new,
      insight_store: Ai::ProfileInsightStore.new
    )
      @account = account
      @profile = profile
      @posts_limit = posts_limit.to_i.clamp(1, MAX_POSTS_LIMIT)
      @comments_limit = comments_limit.to_i.clamp(1, 20)
      @analyze_missing_posts = ActiveModel::Type::Boolean.new.cast(analyze_missing_posts)
      @collector = collector
      @post_analyzer = post_analyzer
      @user_profile_builder_service = user_profile_builder_service
      @face_identity_resolution_service = face_identity_resolution_service
      @insight_store = insight_store
    end

    def prepare!(force: false)
      cached = read_cached_summary
      if !force && cache_valid?(cached)
        return cached.merge(
          "from_cache" => true,
          "ready_for_comment_generation" => ActiveModel::Type::Boolean.new.cast(cached["ready_for_comment_generation"])
        )
      end

      collected_posts = collect_recent_posts
      recent_posts = load_recent_posts(collected_posts: collected_posts)
      analysis = analyze_recent_posts!(recent_posts: recent_posts)
      resolve_identities_for_recent_posts!(recent_posts: recent_posts)
      @user_profile_builder_service.refresh!(profile: @profile)

      identity_consistency = build_identity_consistency
      readiness = build_readiness(analysis: analysis, identity_consistency: identity_consistency, recent_posts_count: recent_posts.length)

      summary = {
        "version" => PREPARATION_VERSION,
        "prepared_at" => Time.current.iso8601,
        "profile_id" => @profile.id,
        "instagram_account_id" => @account.id,
        "posts_limit" => @posts_limit,
        "comments_limit" => @comments_limit,
        "recent_posts_count" => recent_posts.length,
        "analysis" => analysis,
        "identity_consistency" => identity_consistency,
        "ready_for_comment_generation" => readiness[:ready],
        "reason_code" => readiness[:reason_code],
        "reason" => readiness[:reason]
      }

      persist_summary(summary)
      summary
    rescue StandardError => e
      summary = {
        "version" => PREPARATION_VERSION,
        "prepared_at" => Time.current.iso8601,
        "profile_id" => @profile&.id,
        "instagram_account_id" => @account&.id,
        "ready_for_comment_generation" => false,
        "reason_code" => "profile_preparation_failed",
        "reason" => e.message.to_s,
        "error_class" => e.class.name
      }
      persist_summary(summary)
      summary
    end

    private

    def collect_recent_posts
      collector = @collector || Instagram::ProfileAnalysisCollector.new(account: @account, profile: @profile)
      result = collector.collect_and_persist!(posts_limit: @posts_limit, comments_limit: @comments_limit)
      Array(result[:posts]).compact
    rescue StandardError
      []
    end

    def load_recent_posts(collected_posts:)
      rows = Array(collected_posts).select(&:persisted?)
      if rows.empty?
        rows = @profile.instagram_profile_posts.recent_first.limit(@posts_limit).to_a
      end
      rows.sort_by { |post| [ post.taken_at || Time.at(0), post.id.to_i ] }.reverse.first(@posts_limit)
    end

    def analyze_recent_posts!(recent_posts:)
      analyzer = @post_analyzer || method(:analyze_post!)
      analyzed = 0
      pending = 0
      failed = []
      structured_signals = 0
      insight_store_refreshed = 0

      recent_posts.each do |post|
        begin
          if !post_analyzed?(post)
            if @analyze_missing_posts
              analyzer.call(post)
              post.reload
            else
              pending += 1
              next
            end
          end

          if post_analyzed?(post)
            analyzed += 1
            ingest_post_signals!(post: post)
            insight_store_refreshed += 1
            ensure_post_face_recognition!(post: post)
            structured_signals += 1 if post_has_structured_signals?(post)
          else
            pending += 1
          end
        rescue StandardError => e
          failed << {
            "post_id" => post.id,
            "shortcode" => post.shortcode,
            "error" => e.message.to_s
          }
        end
      end

      {
        "analyzed_posts_count" => analyzed,
        "pending_posts_count" => pending,
        "failed_posts_count" => failed.length,
        "failed_posts" => failed.first(12),
        "posts_with_structured_signals_count" => structured_signals,
        "insight_store_refreshed_posts_count" => insight_store_refreshed,
        "latest_posts_analyzed" => (pending.zero? && failed.empty?)
      }
    end

    def analyze_post!(post)
      AnalyzeInstagramProfilePostJob.perform_now(
        instagram_account_id: @account.id,
        instagram_profile_id: @profile.id,
        instagram_profile_post_id: post.id,
        pipeline_mode: "inline",
        task_flags: {
          generate_comments: false
        }
      )
    end

    def post_analyzed?(post)
      post.ai_status.to_s == "analyzed" && post.analyzed_at.present?
    end

    def ensure_post_face_recognition!(post:)
      return unless post.media.attached?
      return unless post.media.blob&.content_type.to_s.start_with?("image/")
      return if post.instagram_post_faces.exists?

      PostFaceRecognitionService.new.process!(post: post)
    rescue StandardError
      nil
    end

    def ingest_post_signals!(post:)
      @insight_store.ingest_post!(
        profile: @profile,
        post: post,
        analysis: post.analysis,
        metadata: post.metadata
      )
    rescue StandardError
      nil
    end

    def post_has_structured_signals?(post)
      analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
      image_description = analysis["image_description"].to_s
      topics = Array(analysis["topics"])
      suggestions = Array(analysis["comment_suggestions"])
      entities = analysis["entities"].is_a?(Hash) ? analysis["entities"] : {}

      image_description.present? || topics.any? || suggestions.any? || entities.any?
    end

    def resolve_identities_for_recent_posts!(recent_posts:)
      recent_posts.each do |post|
        next unless post.instagram_post_faces.exists?

        @face_identity_resolution_service.resolve_for_post!(
          post: post,
          extracted_usernames: extracted_usernames_for_post(post),
          content_summary: post.analysis.is_a?(Hash) ? post.analysis : {}
        )
      rescue StandardError
        next
      end
    end

    def extracted_usernames_for_post(post)
      analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
      rows = []
      rows.concat(Array(analysis["mentions"]))
      rows.concat(Array(analysis["profile_handles"]))
      rows.concat(analysis["ocr_text"].to_s.scan(/@[a-zA-Z0-9._]{2,30}/))
      rows.concat(post.caption.to_s.scan(/@[a-zA-Z0-9._]{2,30}/))
      rows.map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(20)
    end

    def build_identity_consistency
      counts = InstagramPostFace.joins(:instagram_profile_post)
        .where(instagram_profile_posts: { instagram_profile_id: @profile.id })
        .where.not(instagram_story_person_id: nil)
        .group(:instagram_story_person_id)
        .count

      total_faces = counts.values.sum.to_i
      return {
        "consistent" => false,
        "reason_code" => "insufficient_face_data",
        "reason" => "No recognized faces found across analyzed posts.",
        "total_faces" => total_faces
      } if total_faces <= 0

      person_id, appearances = counts.max_by { |_id, value| value.to_i }
      appearances = appearances.to_i
      dominance_ratio = (appearances.to_f / total_faces.to_f).round(4)
      min_primary_appearances = FaceIdentityResolutionService::MIN_PRIMARY_APPEARANCES
      min_primary_ratio = FaceIdentityResolutionService::MIN_PRIMARY_RATIO

      person = @profile.instagram_story_people.find_by(id: person_id)
      linked_usernames = Array(person&.metadata&.dig("linked_usernames")).map { |value| normalize_username(value) }.reject(&:blank?)
      profile_username = normalize_username(@profile.username)
      label_username = normalize_username(person&.label)

      account_owner_match = linked_usernames.include?(profile_username) ||
        label_username == profile_username ||
        person&.role.to_s == "primary_user"

      consistent = appearances >= min_primary_appearances &&
        dominance_ratio >= min_primary_ratio &&
        account_owner_match

      reason_code =
        if !account_owner_match
          "primary_identity_not_linked_to_profile"
        elsif appearances < min_primary_appearances
          "insufficient_primary_appearances"
        elsif dominance_ratio < min_primary_ratio
          "identity_majority_not_confirmed"
        else
          "identity_consistent"
        end

      reason =
        if consistent
          "Primary identity is consistent across recent analyzed posts."
        else
          "Primary identity consistency requirements were not met (#{reason_code})."
        end

      {
        "consistent" => consistent,
        "reason_code" => reason_code,
        "reason" => reason,
        "primary_person_id" => person_id,
        "primary_role" => person&.role.to_s.presence,
        "appearance_count" => appearances,
        "total_faces" => total_faces,
        "dominance_ratio" => dominance_ratio,
        "linked_usernames" => linked_usernames.first(10)
      }.compact
    rescue StandardError => e
      {
        "consistent" => false,
        "reason_code" => "identity_consistency_error",
        "reason" => e.message.to_s,
        "error_class" => e.class.name
      }
    end

    def build_readiness(analysis:, identity_consistency:, recent_posts_count:)
      analysis_data = analysis.is_a?(Hash) ? analysis : {}
      identity_data = identity_consistency.is_a?(Hash) ? identity_consistency : {}

      analyzed_posts_count = analysis_data["analyzed_posts_count"].to_i
      structured_signals_count = analysis_data["posts_with_structured_signals_count"].to_i
      latest_posts_analyzed = ActiveModel::Type::Boolean.new.cast(analysis_data["latest_posts_analyzed"])
      identity_consistent = ActiveModel::Type::Boolean.new.cast(identity_data["consistent"])
      required_analyzed = [ recent_posts_count.to_i, MIN_REQUIRED_ANALYZED_POSTS ].min

      if recent_posts_count.to_i <= 0
        return {
          ready: false,
          reason_code: "no_recent_posts_available",
          reason: "No recent posts are available to build verified profile context."
        }
      end
      unless latest_posts_analyzed
        return {
          ready: false,
          reason_code: "latest_posts_not_analyzed",
          reason: "Latest posts have not been fully analyzed yet."
        }
      end
      if analyzed_posts_count < required_analyzed
        return {
          ready: false,
          reason_code: "insufficient_analyzed_posts",
          reason: "Insufficient analyzed posts for reliable historical context."
        }
      end
      if structured_signals_count <= 0
        return {
          ready: false,
          reason_code: "missing_structured_post_signals",
          reason: "Recent posts do not contain enough structured metadata for grounded comments."
        }
      end
      unless identity_consistent
        return {
          ready: false,
          reason_code: identity_data["reason_code"].to_s.presence || "identity_consistency_not_confirmed",
          reason: identity_data["reason"].to_s.presence || "Identity consistency could not be confirmed."
        }
      end

      {
        ready: true,
        reason_code: "profile_context_ready",
        reason: "Profile history, latest post analysis, and identity consistency verified."
      }
    end

    def read_cached_summary
      metadata = @profile.instagram_profile_behavior_profile&.metadata
      return {} unless metadata.is_a?(Hash)

      summary = metadata["comment_generation_preparation"]
      summary.is_a?(Hash) ? summary : {}
    end

    def cache_valid?(summary)
      prepared_at = parse_time(summary["prepared_at"])
      return false unless prepared_at
      return false if summary["version"].to_s != PREPARATION_VERSION

      prepared_at >= CACHE_TTL.ago
    end

    def persist_summary(summary)
      record = InstagramProfileBehaviorProfile.find_or_initialize_by(instagram_profile: @profile)
      metadata = record.metadata.is_a?(Hash) ? record.metadata.deep_dup : {}
      metadata["comment_generation_preparation"] = summary
      record.metadata = metadata
      record.activity_score = record.activity_score.to_f
      record.behavioral_summary = {} unless record.behavioral_summary.is_a?(Hash)
      record.save!
    rescue StandardError
      nil
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def normalize_username(value)
      text = value.to_s.strip.downcase
      text = text.delete_prefix("@")
      text.presence
    end
  end
end
