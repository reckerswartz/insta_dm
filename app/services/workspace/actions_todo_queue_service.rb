require "set"

module Workspace
  class ActionsTodoQueueService
    DEFAULT_LIMIT = 30
    MAX_LIMIT = 120
    MAX_POST_AGE_DAYS = 5
    PRELOAD_MULTIPLIER = 8
    ENQUEUE_BATCH_SIZE = ENV.fetch("WORKSPACE_ACTIONS_ENQUEUE_BATCH_SIZE", 8).to_i.clamp(1, 30)
    NON_PROCESSABLE_STATUSES = %w[
      ready
      failed
      skipped_page_profile
      skipped_deleted_source
      skipped_non_user_post
    ].freeze

    def initialize(account:, limit: DEFAULT_LIMIT, enqueue_processing: true, now: Time.current)
      @account = account
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @enqueue_processing = ActiveModel::Type::Boolean.new.cast(enqueue_processing)
      @now = now
      @profile_policy_cache = {}
    end

    def fetch!
      posts = candidate_posts
      return empty_result if posts.empty?

      sent_keys = commented_post_keys(profile_ids: posts.map(&:instagram_profile_id).uniq)
      items = posts.filter_map { |post| build_item(post: post, sent_keys: sent_keys) }
      return empty_result if items.empty?

      ordered = sort_items(items: items)
      enqueue_result = @enqueue_processing ? enqueue_processing_jobs(items: ordered) : { enqueued_count: 0, blocked_reason: nil }

      {
        items: ordered.first(@limit),
        stats: {
          total_items: ordered.length,
          ready_items: ordered.count { |row| row[:suggestions].any? },
          processing_items: ordered.count { |row| row[:requires_processing] },
          enqueued_now: enqueue_result[:enqueued_count].to_i,
          enqueue_blocked_reason: enqueue_result[:blocked_reason].to_s.presence,
          refreshed_at: @now.iso8601(3)
        }
      }
    end

    private

    attr_reader :account, :limit, :now

    def empty_result
      {
        items: [],
        stats: {
          total_items: 0,
          ready_items: 0,
          processing_items: 0,
          enqueued_now: 0,
          enqueue_blocked_reason: nil,
          refreshed_at: now.iso8601(3)
        }
      }
    end

    def candidate_posts
      scope_limit = [ limit * PRELOAD_MULTIPLIER, limit ].max
      cutoff = MAX_POST_AGE_DAYS.days.ago

      account.instagram_profile_posts
        .includes(instagram_profile: :profile_tags, media_attachment: :blob, preview_image_attachment: :blob)
        .where("taken_at >= ?", cutoff)
        .order(taken_at: :desc, id: :desc)
        .limit(scope_limit)
        .to_a
    rescue StandardError
      []
    end

    def build_item(post:, sent_keys:)
      profile = post.instagram_profile
      return nil unless profile
      return nil unless user_profile?(profile)
      return nil if source_deleted_post?(post)
      return nil unless user_created_post?(post)

      comment_key = "#{post.instagram_profile_id}:#{post.shortcode}"
      return nil if sent_keys.include?(comment_key)

      analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      policy = metadata["comment_generation_policy"].is_a?(Hash) ? metadata["comment_generation_policy"] : {}
      workspace_state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"] : {}
      suggestions = Array(analysis["comment_suggestions"]).map { |value| value.to_s.strip }.reject(&:blank?).uniq.first(3)
      processing_status = derive_processing_status(post: post, suggestions: suggestions, workspace_state: workspace_state, policy: policy)
      processing_message = derive_processing_message(processing_status: processing_status, workspace_state: workspace_state, policy: policy, post: post)

      {
        post: post,
        profile: profile,
        analysis: analysis,
        metadata: metadata,
        suggestions: suggestions,
        policy: policy,
        workspace_state: workspace_state,
        processing_status: processing_status,
        processing_message: processing_message,
        requires_processing: suggestions.empty? && !NON_PROCESSABLE_STATUSES.include?(processing_status.to_s),
        post_taken_at: post.taken_at,
        profile_last_active_at: profile.last_active_at
      }
    end

    def derive_processing_status(post:, suggestions:, workspace_state:, policy:)
      return "ready" if suggestions.any?

      status = workspace_state["status"].to_s
      return status if status.present?

      return "waiting_media_download" unless post.media.attached?

      ai_status = post.ai_status.to_s
      return "waiting_post_analysis" if ai_status == "pending" || ai_status == "running"

      reason_code = policy["history_reason_code"].to_s
      if policy["status"].to_s == "blocked" && reason_code.in?(WorkspaceProcessActionsTodoPostJob::PROFILE_INCOMPLETE_REASON_CODES)
        return "waiting_build_history"
      end

      "queued_for_processing"
    end

    def derive_processing_message(processing_status:, workspace_state:, policy:, post:)
      case processing_status.to_s
      when "ready"
        "Suggestions are ready."
      when "waiting_media_download"
        "Preview media download is queued."
      when "waiting_post_analysis"
        "Post analysis is running in background."
      when "waiting_comment_generation"
        "Comment suggestions are generating in background."
      when "waiting_build_history", "waiting_profile_analysis"
        "Build History is running; comment generation will resume automatically."
      when "running"
        "Preparing suggestions in background."
      when "queued"
        "Queued for background processing."
      when "failed"
        workspace_state["last_error"].to_s.presence || "Background processing failed. Will retry."
      when "skipped_page_profile"
        "Skipped because this account is classified as a page."
      when "skipped_deleted_source"
        "Skipped because this post was deleted from source."
      when "skipped_non_user_post"
        "Skipped because this row is not a user-created post."
      else
        if post.ai_status.to_s == "analyzed"
          policy["blocked_reason"].to_s.presence || "Awaiting comment suggestions."
        else
          "Queued for analysis and suggestion generation."
        end
      end
    end

    def sort_items(items:)
      status_priority = {
        "failed" => 6,
        "running" => 5,
        "queued" => 4,
        "waiting_build_history" => 4,
        "waiting_profile_analysis" => 4,
        "waiting_comment_generation" => 4,
        "waiting_post_analysis" => 3,
        "waiting_media_download" => 3,
        "queued_for_processing" => 2,
        "ready" => 1,
        "skipped_non_user_post" => 0,
        "skipped_deleted_source" => 0,
        "skipped_page_profile" => 0
      }

      items.sort_by do |item|
        [
          status_priority[item[:processing_status].to_s].to_i,
          item[:profile_last_active_at] || Time.at(0),
          item[:post_taken_at] || Time.at(0)
        ]
      end.reverse
    end

    def enqueue_processing_jobs(items:)
      queue_health = queue_health_status
      unless ActiveModel::Type::Boolean.new.cast(queue_health[:ok])
        reason = queue_health[:reason].to_s.presence || "queue_unhealthy"
        Ops::StructuredLogger.warn(
          event: "workspace.actions_queue.enqueue_skipped",
          payload: {
            instagram_account_id: account.id,
            reason: reason,
            counts: queue_health[:counts].is_a?(Hash) ? queue_health[:counts] : {}
          }
        )
        return { enqueued_count: 0, blocked_reason: reason }
      end

      candidates = items.select { |item| item[:requires_processing] }.first(ENQUEUE_BATCH_SIZE)
      enqueued = 0

      candidates.each do |item|
        result = WorkspaceProcessActionsTodoPostJob.enqueue_if_needed!(
          account: account,
          profile: item[:profile],
          post: item[:post],
          requested_by: "workspace_actions_queue"
        )
        enqueued += 1 if ActiveModel::Type::Boolean.new.cast(result[:enqueued])
      rescue StandardError
        next
      end

      { enqueued_count: enqueued, blocked_reason: nil }
    rescue StandardError => e
      Ops::StructuredLogger.error(
        event: "workspace.actions_queue.enqueue_check_failed",
        payload: {
          instagram_account_id: account.id,
          error_class: e.class.name,
          error_message: e.message.to_s
        }
      )
      { enqueued_count: 0, blocked_reason: "queue_check_failed" }
    end

    def queue_health_status
      Rails.cache.fetch("ops/workspace_actions_queue_health", expires_in: 20.seconds) do
        Ops::QueueHealth.check!
      end
    end

    def user_profile?(profile)
      decision = cached_profile_decision(profile: profile)
      return false if ActiveModel::Type::Boolean.new.cast(decision[:skip_post_analysis])

      tag_names = profile.profile_tags.map { |tag| tag.name.to_s.downcase }
      return false if tag_names.any? { |name| %w[page brand business company publisher].include?(name) }

      true
    rescue StandardError
      false
    end

    def cached_profile_decision(profile:)
      @profile_policy_cache[profile.id] ||= Instagram::ProfileScanPolicy.new(profile: profile).decision
    end

    def source_deleted_post?(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      ActiveModel::Type::Boolean.new.cast(metadata["deleted_from_source"])
    end

    def user_created_post?(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      post_kind = metadata["post_kind"].to_s.downcase
      return false if post_kind == "story"

      product_type = metadata["product_type"].to_s.downcase
      return false if product_type == "story"
      return false if ActiveModel::Type::Boolean.new.cast(metadata["is_story"])

      true
    rescue StandardError
      false
    end

    def commented_post_keys(profile_ids:)
      return Set.new if profile_ids.blank?

      events =
        InstagramProfileEvent
          .joins(:instagram_profile)
          .where(instagram_profiles: { instagram_account_id: account.id, id: profile_ids })
          .where(kind: "post_comment_sent")
          .order(detected_at: :desc, id: :desc)
          .limit(2_000)

      Set.new(
        events.filter_map do |event|
          shortcode = event.metadata.is_a?(Hash) ? event.metadata["post_shortcode"].to_s.strip : ""
          next if shortcode.blank?

          "#{event.instagram_profile_id}:#{shortcode}"
        end
      )
    rescue StandardError
      Set.new
    end
  end
end
