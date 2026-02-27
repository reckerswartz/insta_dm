# frozen_string_literal: true

module Ops
  class StoryCommentSpecificityAudit
    DEFAULT_LIMIT = 24
    DEFAULT_WAIT_TIMEOUT_SECONDS = 900
    DEFAULT_POLL_INTERVAL_SECONDS = 10
    IN_PROGRESS_STATUSES = %w[queued running].freeze

    def initialize(account_id: nil, story_ids: nil, limit: nil, regenerate: false, wait: false, wait_timeout_seconds: nil, poll_interval_seconds: nil)
      @account_id = account_id.to_s.strip.presence
      @story_ids = normalize_story_ids(story_ids)
      @limit = normalize_limit(limit)
      @regenerate = ActiveModel::Type::Boolean.new.cast(regenerate)
      @wait = ActiveModel::Type::Boolean.new.cast(wait)
      @wait_timeout_seconds = normalize_wait_timeout(wait_timeout_seconds)
      @poll_interval_seconds = normalize_poll_interval(poll_interval_seconds)
    end

    def call
      events = selected_events
      before = build_snapshots(events)
      queued = regenerate ? enqueue_regeneration(events) : []
      wait_result = wait ? wait_for_completion(events) : { waited: false, timed_out: false, iterations: 0 }
      events.each(&:reload)
      after = build_snapshots(events)

      {
        account_id: account_id,
        story_ids: story_ids,
        limit: limit,
        regenerate: regenerate,
        wait: wait,
        selected_count: events.size,
        queued_count: queued.count { |row| row[:queued] },
        queued: queued,
        wait_result: wait_result,
        summary_before: summarize(before),
        summary_after: summarize(after),
        comparisons: compare_snapshots(before: before, after: after)
      }
    end

    private

    attr_reader :account_id, :story_ids, :limit, :regenerate, :wait, :wait_timeout_seconds, :poll_interval_seconds

    def normalize_story_ids(raw)
      rows = Array(raw).flat_map { |value| value.to_s.split(",") }
      rows.map { |value| value.to_s.strip }.reject(&:blank?).uniq.first(150)
    end

    def normalize_limit(value)
      parsed = value.to_i
      parsed = DEFAULT_LIMIT if parsed <= 0
      parsed.clamp(1, 100)
    end

    def normalize_wait_timeout(value)
      parsed = value.to_i
      parsed = DEFAULT_WAIT_TIMEOUT_SECONDS if parsed <= 0
      parsed.clamp(30, 7200)
    end

    def normalize_poll_interval(value)
      parsed = value.to_i
      parsed = DEFAULT_POLL_INTERVAL_SECONDS if parsed <= 0
      parsed.clamp(1, 60)
    end

    def selected_events
      rows = base_scope.to_a
      selected = []
      seen_keys = {}

      rows.each do |event|
        story_id = event_story_id(event)
        key = "#{event.instagram_profile_id}:#{story_id.presence || event.id}"
        next if seen_keys[key]

        selected << event
        seen_keys[key] = true
        break if selected.size >= limit
      end

      selected
    end

    def base_scope
      scope = InstagramProfileEvent
        .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
        .joins(:instagram_profile)
        .includes(:instagram_profile)
        .order(detected_at: :desc, id: :desc)

      scope = scope.where(instagram_profiles: { instagram_account_id: account_id }) if account_id.present?
      scope = scope.where("metadata ->> 'story_id' IN (?)", story_ids) if story_ids.any?
      scope
    end

    def event_story_id(event)
      meta = event.metadata.is_a?(Hash) ? event.metadata : {}
      meta["story_id"].to_s.strip.presence
    end

    def build_snapshots(events)
      Array(events).map { |event| snapshot_for(event) }
    end

    def snapshot_for(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      generation_inputs = llm_meta["generation_inputs"].is_a?(Hash) ? llm_meta["generation_inputs"] : {}
      policy_diagnostics = llm_meta["policy_diagnostics"].is_a?(Hash) ? llm_meta["policy_diagnostics"] : {}

      anchors = normalized_strings(generation_inputs["visual_anchors"], max: 10)
      topics = normalized_strings(generation_inputs["selected_topics"], max: 10)
      keywords = normalized_strings(generation_inputs["context_keywords"], max: 14)
      comment = event.llm_generated_comment.to_s.strip
      source = llm_meta["source"].to_s

      {
        event_id: event.id,
        profile_id: event.instagram_profile_id,
        story_id: event_story_id(event),
        llm_status: event.llm_comment_status.to_s,
        generation_status: llm_meta["generation_status"].to_s,
        source: source,
        fallback_used: source == "fallback",
        model: event.llm_comment_model.to_s,
        provider: event.llm_comment_provider.to_s,
        selected_topics: topics,
        visual_anchors: anchors,
        context_keywords: keywords,
        content_mode: generation_inputs["content_mode"].to_s.presence,
        signal_score: generation_inputs["signal_score"].to_i,
        comment: comment,
        comment_signature: comment_signature(comment),
        anchor_signature: anchors.first(6).join("|"),
        rejected_reason_counts: policy_diagnostics["rejected_reason_counts"].is_a?(Hash) ? policy_diagnostics["rejected_reason_counts"] : {},
        failure_reason: llm_meta.dig("last_failure", "reason").to_s.presence
      }
    end

    def normalized_strings(values, max:)
      Array(values)
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .first(max.to_i.clamp(1, 64))
    end

    def comment_signature(comment)
      return "" if comment.to_s.blank?

      comment.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").gsub(/\s+/, " ").strip.byteslice(0, 120)
    end

    def enqueue_regeneration(events)
      Array(events).map do |event|
        account = event.instagram_profile&.instagram_account
        unless account
          next {
            event_id: event.id,
            story_id: event_story_id(event),
            queued: false,
            error: "missing_account"
          }
        end

        result = InstagramAccounts::LlmCommentRequestService.new(
          account: account,
          event_id: event.id,
          provider: :local,
          model: nil,
          status_only: false,
          force: true,
          regenerate_all: true
        ).call

        {
          event_id: event.id,
          story_id: event_story_id(event),
          queued: result.status.to_s.in?(%w[accepted ok]),
          response_status: result.status.to_s,
          llm_status: result.payload[:status].to_s,
          job_id: result.payload[:job_id].to_s.presence
        }
      rescue StandardError => e
        {
          event_id: event.id,
          story_id: event_story_id(event),
          queued: false,
          error: "#{e.class}: #{e.message}"
        }
      end
    end

    def wait_for_completion(events)
      ids = Array(events).map(&:id).compact
      return { waited: true, timed_out: false, iterations: 0, remaining_in_progress: 0 } if ids.empty?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      iterations = 0
      timed_out = false

      loop do
        iterations += 1
        current = InstagramProfileEvent.where(id: ids).pluck(:id, :llm_comment_status).to_h
        remaining = current.values.count { |status| IN_PROGRESS_STATUSES.include?(status.to_s) }
        break if remaining.zero?

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        if elapsed >= wait_timeout_seconds
          timed_out = true
          break
        end

        sleep poll_interval_seconds
      end

      final = InstagramProfileEvent.where(id: ids).pluck(:llm_comment_status)
      {
        waited: true,
        timed_out: timed_out,
        iterations: iterations,
        remaining_in_progress: final.count { |status| IN_PROGRESS_STATUSES.include?(status.to_s) }
      }
    end

    def summarize(rows)
      data = Array(rows).select { |row| row.is_a?(Hash) }
      total = data.size
      fallback_count = data.count { |row| ActiveModel::Type::Boolean.new.cast(row[:fallback_used]) }
      completed_count = data.count { |row| row[:llm_status].to_s == "completed" }

      anchor_hist = Hash.new(0)
      comment_hist = Hash.new(0)
      data.each do |row|
        anchor_sig = row[:anchor_signature].to_s
        anchor_hist[anchor_sig] += 1 if anchor_sig.present?
        comment_sig = row[:comment_signature].to_s
        comment_hist[comment_sig] += 1 if comment_sig.present?
      end

      {
        total: total,
        completed_count: completed_count,
        fallback_count: fallback_count,
        fallback_ratio: total.positive? ? (fallback_count.to_f / total.to_f).round(3) : 0.0,
        unique_anchor_signatures: anchor_hist.keys.size,
        repeated_anchor_signatures: anchor_hist.select { |_sig, count| count > 1 }.sort_by { |_sig, count| -count }.first(12).to_h,
        repeated_comment_signatures: comment_hist.select { |_sig, count| count > 1 }.sort_by { |_sig, count| -count }.first(12).to_h
      }
    end

    def compare_snapshots(before:, after:)
      before_by_id = Array(before).index_by { |row| row[:event_id] }
      after_by_id = Array(after).index_by { |row| row[:event_id] }
      ids = (before_by_id.keys + after_by_id.keys).uniq

      ids.map do |event_id|
        pre = before_by_id[event_id] || {}
        post = after_by_id[event_id] || {}
        changed = %i[
          llm_status
          generation_status
          source
          selected_topics
          visual_anchors
          content_mode
          signal_score
          comment
        ].select { |key| pre[key] != post[key] }

        {
          event_id: event_id,
          story_id: post[:story_id] || pre[:story_id],
          changed_fields: changed,
          before: pre,
          after: post
        }
      end
    end
  end
end
