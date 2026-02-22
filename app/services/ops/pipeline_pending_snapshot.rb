module Ops
  class PipelinePendingSnapshot
    DEFAULT_ITEM_LIMIT = ENV.fetch("PIPELINE_PENDING_ITEM_LIMIT", 12).to_i.clamp(1, 100)
    DEFAULT_REASON_LIMIT = ENV.fetch("PIPELINE_PENDING_REASON_LIMIT", 12).to_i.clamp(1, 50)
    STALE_AFTER_MINUTES = ENV.fetch("PIPELINE_PENDING_STALE_AFTER_MINUTES", 20).to_i.clamp(5, 240)
    CACHE_TTL_SECONDS = ENV.fetch("PIPELINE_PENDING_CACHE_TTL_SECONDS", 15).to_i.clamp(0, 300)
    CACHE_VERSION = "v1".freeze

    class << self
      def snapshot(account_id: nil, item_limit: DEFAULT_ITEM_LIMIT, reason_limit: DEFAULT_REASON_LIMIT, use_cache: true)
        normalized_account_id = account_id.to_i.positive? ? account_id.to_i : nil
        normalized_item_limit = item_limit.to_i.clamp(1, 100)
        normalized_reason_limit = reason_limit.to_i.clamp(1, 50)
        cache_key = cache_key_for(
          account_id: normalized_account_id,
          item_limit: normalized_item_limit,
          reason_limit: normalized_reason_limit
        )

        if use_cache && cache_key
          return Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS.seconds) do
            build_snapshot(
              account_id: normalized_account_id,
              item_limit: normalized_item_limit,
              reason_limit: normalized_reason_limit
            )
          end
        end

        build_snapshot(
          account_id: normalized_account_id,
          item_limit: normalized_item_limit,
          reason_limit: normalized_reason_limit
        )
      end

      private

      def build_snapshot(account_id:, item_limit:, reason_limit:)
        now = Time.current
        stale_cutoff = now - STALE_AFTER_MINUTES.minutes
        post_scope = pending_post_scope(account_id: account_id)
        story_scope = pending_story_scope(account_id: account_id)

        {
          captured_at: now.iso8601(3),
          account_id: account_id,
          stale_after_minutes: STALE_AFTER_MINUTES,
          posts: build_post_snapshot(
            scope: post_scope,
            item_limit: item_limit,
            reason_limit: reason_limit,
            now: now,
            stale_cutoff: stale_cutoff
          ),
          story_events: build_story_snapshot(
            scope: story_scope,
            item_limit: item_limit,
            reason_limit: reason_limit,
            now: now,
            stale_cutoff: stale_cutoff
          )
        }
      rescue StandardError
        empty_snapshot(account_id: account_id)
      end

      def build_post_snapshot(scope:, item_limit:, reason_limit:, now:, stale_cutoff:)
        rows = ordered_post_rows(scope: scope, item_limit: item_limit)

        {
          pending_total: scope.count.to_i,
          running_total: scope.where(ai_status: "running").count.to_i,
          queued_total: scope.where(ai_status: "pending").count.to_i,
          with_estimate_total: scope.where.not(ai_estimated_ready_at: nil).count.to_i,
          with_retry_total: scope.where.not(ai_next_retry_at: nil).count.to_i,
          overdue_total: scope.where.not(ai_estimated_ready_at: nil).where("ai_estimated_ready_at < ?", now).count.to_i,
          stale_total: scope.where.not(ai_pending_since_at: nil).where("ai_pending_since_at < ?", stale_cutoff).count.to_i,
          reasons: reason_rows(
            scope: scope,
            reason_column: :ai_pending_reason_code,
            step_column: :ai_blocking_step,
            estimated_column: :ai_estimated_ready_at,
            reason_limit: reason_limit,
            now: now,
            queue_name_resolver: method(:queue_name_for_post_step)
          ),
          blocking_steps: blocking_step_rows(
            scope: scope,
            step_column: :ai_blocking_step,
            limit: reason_limit,
            queue_name_resolver: method(:queue_name_for_post_step)
          ),
          items: rows.map { |row| post_item_payload(row: row, now: now) }
        }
      rescue StandardError
        empty_pipeline_scope_snapshot
      end

      def build_story_snapshot(scope:, item_limit:, reason_limit:, now:, stale_cutoff:)
        rows = ordered_story_rows(scope: scope, item_limit: item_limit)

        {
          pending_total: scope.count.to_i,
          running_total: scope.where(llm_comment_status: "running").count.to_i,
          queued_total: scope.where(llm_comment_status: "queued").count.to_i,
          with_estimate_total: scope.where.not(llm_estimated_ready_at: nil).count.to_i,
          overdue_total: scope.where.not(llm_estimated_ready_at: nil).where("llm_estimated_ready_at < ?", now).count.to_i,
          stale_total: scope.where("instagram_profile_events.updated_at < ?", stale_cutoff).count.to_i,
          reasons: reason_rows(
            scope: scope,
            reason_column: :llm_pending_reason_code,
            step_column: :llm_blocking_step,
            estimated_column: :llm_estimated_ready_at,
            reason_limit: reason_limit,
            now: now,
            queue_name_resolver: method(:queue_name_for_story_step)
          ),
          blocking_steps: blocking_step_rows(
            scope: scope,
            step_column: :llm_blocking_step,
            limit: reason_limit,
            queue_name_resolver: method(:queue_name_for_story_step)
          ),
          items: rows.map { |row| story_item_payload(row: row, now: now) }
        }
      rescue StandardError
        empty_pipeline_scope_snapshot
      end

      def pending_post_scope(account_id:)
        scope = InstagramProfilePost.where(
          "ai_status IN (?) OR ai_blocking_step IS NOT NULL OR ai_pending_reason_code IS NOT NULL",
          %w[pending running]
        )
        return scope unless account_id.to_i.positive?

        scope.where(instagram_account_id: account_id.to_i)
      rescue StandardError
        InstagramProfilePost.none
      end

      def pending_story_scope(account_id:)
        scope = InstagramProfileEvent
          .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
          .where(
            "llm_comment_status IN (?) OR llm_blocking_step IS NOT NULL OR llm_pending_reason_code IS NOT NULL",
            %w[queued running]
          )
        return scope unless account_id.to_i.positive?

        scope
          .joins(:instagram_profile)
          .where(instagram_profiles: { instagram_account_id: account_id.to_i })
      rescue StandardError
        InstagramProfileEvent.none
      end

      def ordered_post_rows(scope:, item_limit:)
        rows = scope.includes(:instagram_profile).limit([ item_limit.to_i * 3, item_limit.to_i ].max).to_a
        rows
          .sort_by do |row|
            [
              sortable_time(row.ai_estimated_ready_at),
              sortable_time(row.ai_pending_since_at),
              sortable_time(row.updated_at)
            ]
          end
          .first(item_limit.to_i)
      rescue StandardError
        []
      end

      def ordered_story_rows(scope:, item_limit:)
        rows = scope.includes(:instagram_profile).limit([ item_limit.to_i * 3, item_limit.to_i ].max).to_a
        rows
          .sort_by do |row|
            [
              sortable_time(row.llm_estimated_ready_at),
              sortable_time(row.updated_at)
            ]
          end
          .first(item_limit.to_i)
      rescue StandardError
        []
      end

      def post_item_payload(row:, now:)
        {
          post_id: row.id,
          instagram_profile_id: row.instagram_profile_id,
          profile_username: row.instagram_profile&.username.to_s.presence,
          shortcode: row.shortcode.to_s.presence,
          status: row.ai_status.to_s.presence || "pending",
          pipeline_run_id: row.ai_pipeline_run_id.to_s.presence,
          blocking_step: normalize_label(row.ai_blocking_step),
          pending_reason_code: normalize_label(row.ai_pending_reason_code),
          pending_since_at: iso_time(row.ai_pending_since_at),
          next_retry_at: iso_time(row.ai_next_retry_at),
          estimated_ready_at: iso_time(row.ai_estimated_ready_at),
          pending_age_seconds: seconds_since(time: row.ai_pending_since_at, now: now),
          eta_seconds: seconds_until(time: row.ai_estimated_ready_at, now: now),
          overdue: overdue?(time: row.ai_estimated_ready_at, now: now)
        }.compact
      rescue StandardError
        {}
      end

      def story_item_payload(row:, now:)
        metadata = row.metadata.is_a?(Hash) ? row.metadata : {}
        {
          event_id: row.id,
          instagram_profile_id: row.instagram_profile_id,
          profile_username: row.instagram_profile&.username.to_s.presence,
          story_id: metadata["story_id"].to_s.presence,
          status: row.llm_comment_status.to_s.presence || "queued",
          pipeline_run_id: row.llm_pipeline_run_id.to_s.presence,
          blocking_step: normalize_label(row.llm_blocking_step),
          pending_reason_code: normalize_label(row.llm_pending_reason_code),
          estimated_ready_at: iso_time(row.llm_estimated_ready_at),
          eta_seconds: seconds_until(time: row.llm_estimated_ready_at, now: now),
          overdue: overdue?(time: row.llm_estimated_ready_at, now: now),
          updated_at: iso_time(row.updated_at)
        }.compact
      rescue StandardError
        {}
      end

      def reason_rows(scope:, reason_column:, step_column:, estimated_column:, reason_limit:, now:, queue_name_resolver:)
        groups = scope.group(reason_column, step_column).count
        groups
          .sort_by { |(reason, step), count| [ -count.to_i, reason.to_s, step.to_s ] }
          .first(reason_limit.to_i)
          .map do |(reason, step), count|
            subset = scope.where(reason_column => reason, step_column => step)
            eta_samples =
              subset.where.not(estimated_column => nil).limit(200).pluck(estimated_column).filter_map do |value|
                seconds_until(time: value, now: now)
              end

            {
              reason_code: normalize_label(reason),
              blocking_step: normalize_label(step),
              queue_name: queue_name_resolver.call(step),
              count: count.to_i,
              eta_seconds_median: percentile(samples: eta_samples, percentile: 0.5),
              eta_seconds_p90: percentile(samples: eta_samples, percentile: 0.9),
              overdue_count: eta_samples.count { |value| value.to_i <= 0 }
            }.compact
          end
      rescue StandardError
        []
      end

      def blocking_step_rows(scope:, step_column:, limit:, queue_name_resolver:)
        scope.group(step_column).count
          .sort_by { |step, count| [ -count.to_i, step.to_s ] }
          .first(limit.to_i)
          .map do |step, count|
            {
              blocking_step: normalize_label(step),
              queue_name: queue_name_resolver.call(step),
              count: count.to_i
            }.compact
          end
      rescue StandardError
        []
      end

      def queue_name_for_post_step(step)
        service_key =
          if step.to_s.present?
            Ai::PostAnalysisPipelineState::STEP_TO_QUEUE_SERVICE_KEY[step.to_s]
          else
            :pipeline_orchestration
          end
        queue_name_for_service_key(service_key)
      rescue StandardError
        queue_name_for_service_key(:pipeline_orchestration)
      end

      def queue_name_for_story_step(step)
        service_key =
          if step.to_s.present?
            LlmComment::ParallelPipelineState::STEP_TO_QUEUE_SERVICE_KEY[step.to_s]
          else
            :pipeline_orchestration
          end
        queue_name_for_service_key(service_key)
      rescue StandardError
        queue_name_for_service_key(:pipeline_orchestration)
      end

      def queue_name_for_service_key(service_key)
        Ops::AiServiceQueueRegistry.queue_name_for(service_key).to_s.presence
      rescue StandardError
        nil
      end

      def empty_snapshot(account_id:)
        {
          captured_at: Time.current.iso8601(3),
          account_id: account_id,
          stale_after_minutes: STALE_AFTER_MINUTES,
          posts: empty_pipeline_scope_snapshot,
          story_events: empty_pipeline_scope_snapshot
        }
      end

      def empty_pipeline_scope_snapshot
        {
          pending_total: 0,
          running_total: 0,
          queued_total: 0,
          with_estimate_total: 0,
          with_retry_total: 0,
          overdue_total: 0,
          stale_total: 0,
          reasons: [],
          blocking_steps: [],
          items: []
        }
      end

      def normalize_label(value)
        value.to_s.presence || "unknown"
      end

      def sortable_time(value)
        value || Time.at(2_147_483_647)
      end

      def seconds_until(time:, now:)
        return nil unless time.respond_to?(:to_f)

        (time.to_f - now.to_f).round
      rescue StandardError
        nil
      end

      def seconds_since(time:, now:)
        return nil unless time.respond_to?(:to_f)

        [ (now.to_f - time.to_f).round, 0 ].max
      rescue StandardError
        nil
      end

      def overdue?(time:, now:)
        seconds_until(time: time, now: now).to_i <= 0
      rescue StandardError
        false
      end

      def iso_time(value)
        return nil unless value.respond_to?(:iso8601)

        value.iso8601(3)
      rescue StandardError
        nil
      end

      def percentile(samples:, percentile:)
        rows = Array(samples).map(&:to_i)
        return nil if rows.empty?

        sorted = rows.sort
        index = ((sorted.length - 1) * percentile.to_f).round
        sorted[index]
      rescue StandardError
        nil
      end

      def cache_key_for(account_id:, item_limit:, reason_limit:)
        return nil unless CACHE_TTL_SECONDS.positive?
        return nil unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache

        "ops:pipeline_pending_snapshot:#{CACHE_VERSION}:#{account_id.to_i}:#{item_limit}:#{reason_limit}:#{STALE_AFTER_MINUTES}"
      rescue StandardError
        nil
      end
    end
  end
end
