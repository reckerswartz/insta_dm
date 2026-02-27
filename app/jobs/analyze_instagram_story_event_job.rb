require "net/http"
require "timeout"

class AnalyzeInstagramStoryEventJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:story_analysis)
  AUTO_QUEUE_LLM_COMMENT_ENV_KEY = "STORY_AUTO_QUEUE_LLM_COMMENT".freeze
  MEDIA_WAIT_MAX_ATTEMPTS = ENV.fetch("STORY_ANALYSIS_MEDIA_WAIT_MAX_ATTEMPTS", "3").to_i.clamp(0, 10)
  MEDIA_WAIT_SECONDS = ENV.fetch("STORY_ANALYSIS_MEDIA_WAIT_SECONDS", "12").to_i.clamp(5, 180)
  ANALYSIS_LOCK_NAMESPACE = ENV.fetch("STORY_ANALYSIS_LOCK_NAMESPACE", "87421").to_i
  ANALYSIS_LOCK_WAIT_SECONDS = ENV.fetch("STORY_ANALYSIS_LOCK_WAIT_SECONDS", "10").to_i.clamp(5, 180)
  ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS = ENV.fetch("STORY_ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS", "60").to_i.clamp(1, 200)
  ANALYSIS_TIMEOUT_SECONDS = ENV.fetch("STORY_ANALYSIS_TIMEOUT_SECONDS", "420").to_i.clamp(60, 3600)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(
    instagram_account_id:,
    instagram_profile_id:,
    story_id:,
    story_payload:,
    downloaded_event_id:,
    ingested_story_id: nil,
    auto_reply: false,
    media_wait_attempt: 0,
    analysis_lock_wait_attempt: 0
  )
    analysis_lock_acquired = false
    account = InstagramAccount.find_by(id: instagram_account_id)
    profile = InstagramProfile.find_by(id: instagram_profile_id, instagram_account_id: instagram_account_id)
    return unless account && profile

    sid = story_id.to_s.strip
    return if sid.blank?

    service = analysis_service(account: account, profile: profile)
    story = service.normalized_story_payload(story_payload: story_payload, story_id: sid)
    downloaded_event = profile.instagram_profile_events.find_by(id: downloaded_event_id, kind: "story_downloaded")
    unless downloaded_event&.media&.attached?
      handle_missing_downloaded_story_media!(
        account: account,
        profile: profile,
        story_id: sid,
        story_payload: story_payload,
        downloaded_event_id: downloaded_event_id,
        ingested_story_id: ingested_story_id,
        auto_reply: auto_reply,
        media_wait_attempt: media_wait_attempt,
        analysis_lock_wait_attempt: analysis_lock_wait_attempt,
        reason: downloaded_event ? "downloaded_story_media_missing" : "downloaded_event_missing"
      )
      return
    end

    unless claim_story_analysis_lock!(account_id: account.id)
      handle_story_analysis_lock_busy!(
        account: account,
        profile: profile,
        story_id: sid,
        story_payload: story_payload,
        downloaded_event_id: downloaded_event_id,
        ingested_story_id: ingested_story_id,
        auto_reply: auto_reply,
        media_wait_attempt: media_wait_attempt,
        analysis_lock_wait_attempt: analysis_lock_wait_attempt
      )
      return
    end
    analysis_lock_acquired = true

    mark_analysis_status!(
      profile: profile,
      story_id: sid,
      status: "started",
      extra: {
        "started_at" => Time.current.iso8601(3),
        "active_job_id" => job_id.to_s,
        "queue_name" => queue_name.to_s,
        "waiting_for_analysis_lock" => false,
        "analysis_lock_wait_attempt" => analysis_lock_wait_attempt.to_i
      }
    )

    bytes = downloaded_event.media.blob.download.to_s
    content_type = downloaded_event.media.blob.content_type.to_s.presence || "application/octet-stream"
    analysis = nil
    Timeout.timeout(ANALYSIS_TIMEOUT_SECONDS) do
      analysis = service.analyze_story_for_comments(
        story: story,
        analyzable: downloaded_event,
        bytes: bytes,
        content_type: content_type
      )
    end
    unless analysis[:ok]
      failure_reason = analysis[:failure_reason].to_s.presence || "analysis_not_available"
      error_message = analysis[:error_message].to_s.presence || "Story analysis returned no result."
      error_class = analysis[:error_class].to_s.presence || "StoryAnalysisUnavailableError"
      mark_analysis_status!(
        profile: profile,
        story_id: sid,
        status: "failed",
        extra: {
          "failed_at" => Time.current.iso8601(3),
          "failure_reason" => failure_reason,
          "error_class" => error_class,
          "error_message" => error_message.byteslice(0, 280)
        }
      )
      record_story_analysis_failed_event(
        profile: profile,
        story_id: sid,
        error: StandardError.new(error_message),
        reason: failure_reason,
        downloaded_event_id: downloaded_event&.id
      )
      return
    end

    base_metadata = analysis_queue_metadata(profile: profile, story_id: sid)
    llm_comment_queue = queue_story_comment_generation_if_eligible!(
      event: downloaded_event,
      analysis: analysis
    )
    persist_llm_queue_outcome!(
      event: downloaded_event,
      analysis: analysis,
      queue_result: llm_comment_queue
    )

    ingested_story = InstagramStory.find_by(id: ingested_story_id, instagram_profile_id: profile.id) if ingested_story_id.present?
    analyzed_at = Time.current
    profile.record_event!(
      kind: "story_analyzed",
      external_id: "story_analyzed:#{sid}:#{analyzed_at.utc.iso8601(6)}",
      occurred_at: analyzed_at,
      metadata: base_metadata.merge(
        analyzed_at: analyzed_at.iso8601,
        ai_provider: analysis[:provider],
        ai_model: analysis[:model],
        ai_image_description: analysis[:image_description],
        ai_comment_suggestions: analysis[:comment_suggestions],
        story_generation_policy: analysis[:generation_policy],
        story_ownership_classification: analysis[:ownership_classification],
        instagram_story_id: ingested_story&.id,
        llm_comment_auto_queued: llm_comment_queue[:queued],
        llm_comment_queue_reason: llm_comment_queue[:reason],
        llm_comment_job_id: llm_comment_queue[:job_id],
        llm_comment_queue_name: llm_comment_queue[:queue_name],
        llm_comment_queue_error_class: llm_comment_queue[:error_class],
        llm_comment_queue_error_message: llm_comment_queue[:error_message]
      )
    )

    ReevaluateProfileContentJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      content_type: "story",
      content_id: sid
    )

    reply_queued = nil
    reply_reason = nil
    if ActiveModel::Type::Boolean.new.cast(auto_reply)
      decision = service.story_reply_decision(analysis: analysis, story_id: sid)
      reply_reason = decision[:reason]

      if decision[:queue]
        reply_queued = service.queue_story_reply!(
          story_id: sid,
          analysis: analysis,
          downloaded_event: downloaded_event,
          base_metadata: base_metadata
        )
      else
        reply_queued = false
        profile.record_event!(
          kind: "story_reply_skipped",
          external_id: "story_reply_skipped:#{sid}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_metadata.merge(
            skip_reason: reply_reason,
            relevant: analysis[:relevant],
            author_type: analysis[:author_type],
            suggestions_count: Array(analysis[:comment_suggestions]).length
          )
        )
      end
    end

    mark_analysis_status!(
      profile: profile,
      story_id: sid,
      status: "completed",
      extra: {
        "completed_at" => Time.current.iso8601(3),
        "ai_provider" => analysis[:provider].to_s,
        "ai_model" => analysis[:model].to_s,
        "llm_comment_auto_queued" => llm_comment_queue[:queued],
        "llm_comment_queue_reason" => llm_comment_queue[:reason],
        "llm_comment_job_id" => llm_comment_queue[:job_id],
        "llm_comment_queue_name" => llm_comment_queue[:queue_name],
        "llm_comment_queue_error_class" => llm_comment_queue[:error_class],
        "llm_comment_queue_error_message" => llm_comment_queue[:error_message],
        "reply_queued" => reply_queued,
        "reply_decision_reason" => reply_reason.to_s.presence,
        "waiting_for_analysis_lock" => false
      }.compact
    )
  rescue StandardError => e
    if defined?(profile) && profile && sid.present?
      mark_analysis_status!(
        profile: profile,
        story_id: sid,
        status: "failed",
        extra: {
          "failed_at" => Time.current.iso8601(3),
          "error_class" => e.class.name,
          "error_message" => e.message.to_s.byteslice(0, 280),
          "waiting_for_analysis_lock" => false
        }
      )
      record_story_analysis_failed_event(
        profile: profile,
        story_id: sid,
        error: e,
        downloaded_event_id: defined?(downloaded_event) ? downloaded_event&.id : nil
      )
    end
    raise
  ensure
    release_story_analysis_lock!(account_id: account.id) if analysis_lock_acquired && defined?(account) && account
  end

  private

  def analysis_service(account:, profile:)
    StoryIntelligence::AnalysisService.new(account: account, profile: profile)
  end

  def queue_story_comment_generation_if_eligible!(event:, analysis:)
    return queue_skip(reason: "llm_auto_queue_disabled") unless auto_queue_llm_comment_enabled?
    return queue_skip(reason: "story_archive_item_required") unless event&.story_archive_item?

    policy = analysis[:generation_policy].is_a?(Hash) ? analysis[:generation_policy] : {}
    if allow_comment_present?(policy) && !allow_comment?(policy)
      return queue_skip(
        reason: policy[:reason_code].to_s.presence ||
          policy["reason_code"].to_s.presence ||
          "verified_policy_blocked"
      )
    end

    return queue_skip(reason: "already_completed") if event.has_llm_generated_comment?
    return queue_skip(reason: "already_in_progress") if event.llm_comment_in_progress?

    requested_provider = normalize_requested_provider(analysis[:provider])
    requested_model = analysis[:model].to_s.presence

    job = GenerateLlmCommentJob.perform_later(
      instagram_profile_event_id: event.id,
      provider: requested_provider,
      model: requested_model,
      requested_by: "story_analysis_auto_queue"
    )
    event.queue_llm_comment_generation!(job_id: job.job_id)

    {
      queued: true,
      reason: "queued",
      job_id: job.job_id,
      queue_name: job.queue_name
    }
  rescue StandardError => e
    queue_skip(
      reason: "enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s.byteslice(0, 260)
    )
  end

  def auto_queue_llm_comment_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(AUTO_QUEUE_LLM_COMMENT_ENV_KEY, "true"))
  end

  def allow_comment_present?(policy)
    policy.key?(:allow_comment) || policy.key?("allow_comment")
  end

  def allow_comment?(policy)
    raw = if policy.key?(:allow_comment)
      policy[:allow_comment]
    else
      policy["allow_comment"]
    end
    ActiveModel::Type::Boolean.new.cast(raw)
  end

  def normalize_requested_provider(provider)
    value = provider.to_s
    return "local" if value.blank?
    return value if %w[local ollama].include?(value)

    "local"
  end

  def queue_skip(reason:, error_class: nil, error_message: nil)
    {
      queued: false,
      reason: reason.to_s,
      error_class: error_class.to_s.presence,
      error_message: error_message.to_s.presence
    }.compact
  end

  def persist_llm_queue_outcome!(event:, analysis:, queue_result:)
    return unless event

    outcome = queue_result.is_a?(Hash) ? queue_result.deep_symbolize_keys : {}
    return if ActiveModel::Type::Boolean.new.cast(outcome[:queued])

    reason = outcome[:reason].to_s.presence || "auto_queue_skipped"
    return if reason == "already_in_progress"

    status = llm_status_for_skip_reason(event: event, reason: reason)
    now = Time.current
    message = outcome[:error_message].to_s.presence || llm_skip_message(reason: reason)
    error_class = outcome[:error_class].to_s.presence || llm_skip_error_class(status: status, reason: reason)
    source = llm_skip_source(reason: reason)

    event.with_lock do
      event.reload
      metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
      metadata["generation_policy"] = analysis[:generation_policy] if analysis[:generation_policy].is_a?(Hash)
      metadata["ownership_classification"] = analysis[:ownership_classification] if analysis[:ownership_classification].is_a?(Hash)
      metadata["auto_queue_decision"] = {
        "queued" => false,
        "reason" => reason,
        "source" => source,
        "at" => now.iso8601(3)
      }.compact

      if status.in?(%w[failed skipped])
        metadata["last_failure"] = {
          "reason" => reason,
          "source" => source,
          "error_class" => error_class,
          "error_message" => message,
          "failed_at" => now.iso8601(3)
        }.compact
      end

      updates = {
        llm_comment_status: status,
        llm_comment_last_error: status.in?(%w[failed skipped]) ? message : nil,
        llm_comment_metadata: metadata,
        updated_at: now
      }
      event.update_columns(updates)
    end

    if status == "skipped"
      event.broadcast_llm_comment_generation_skipped(
        message: message,
        reason: reason,
        source: source
      )
    elsif status == "failed"
      event.broadcast_llm_comment_generation_error(message)
    end
  rescue StandardError
    nil
  end

  def llm_status_for_skip_reason(event:, reason:)
    return "completed" if reason == "already_completed" && event.has_llm_generated_comment?
    return "failed" if reason == "enqueue_failed"

    "skipped"
  end

  def llm_skip_message(reason:)
    case reason.to_s
    when "llm_auto_queue_disabled"
      "Automatic comment generation is disabled for story sync."
    when "story_archive_item_required"
      "Story does not meet archive-item requirements for comment generation."
    when "already_completed"
      "Comment generation already completed for this story."
    when "already_in_progress"
      "Comment generation is already in progress."
    when "enqueue_failed"
      "Comment generation job failed to enqueue."
    else
      "Comment generation was skipped (#{reason})."
    end
  end

  def llm_skip_source(reason:)
    value = reason.to_s
    return "auto_queue_setting" if value == "llm_auto_queue_disabled"
    return "story_archive_filter" if value == "story_archive_item_required"
    return "state_guard" if value.in?(%w[already_completed already_in_progress])
    return "job_enqueue" if value == "enqueue_failed"
    return "validated_story_policy" if value.match?(/(policy|third_party|historical_overlap|reshare|meme|unrelated)/)

    "story_analysis_auto_queue"
  end

  def llm_skip_error_class(status:, reason:)
    return "StoryCommentEnqueueError" if status == "failed"
    return "StoryCommentAlreadyCompleted" if reason.to_s == "already_completed"

    "StoryCommentGenerationSkipped"
  end

  def handle_missing_downloaded_story_media!(
    account:,
    profile:,
    story_id:,
    story_payload:,
    downloaded_event_id:,
    ingested_story_id:,
    auto_reply:,
    media_wait_attempt:,
    analysis_lock_wait_attempt:,
    reason:
  )
    attempt = media_wait_attempt.to_i
    if attempt < MEDIA_WAIT_MAX_ATTEMPTS
      retry_job = self.class.set(wait: MEDIA_WAIT_SECONDS.seconds).perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        story_payload: story_payload,
        downloaded_event_id: downloaded_event_id,
        ingested_story_id: ingested_story_id,
        auto_reply: auto_reply,
        media_wait_attempt: attempt + 1,
        analysis_lock_wait_attempt: analysis_lock_wait_attempt.to_i
      )
      mark_analysis_status!(
        profile: profile,
        story_id: story_id,
        status: "queued",
        extra: {
          "waiting_for_media_attachment" => true,
          "media_wait_attempt" => attempt + 1,
          "media_wait_max_attempts" => MEDIA_WAIT_MAX_ATTEMPTS,
          "next_retry_at" => (Time.current + MEDIA_WAIT_SECONDS.seconds).iso8601(3),
          "status_reason" => reason.to_s,
          "waiting_for_analysis_lock" => false,
          "active_job_id" => retry_job&.job_id.to_s.presence,
          "queue_name" => retry_job&.queue_name.to_s.presence
        }.compact
      )
      Ops::StructuredLogger.warn(
        event: "story_analysis.waiting_for_media_attachment",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          story_id: story_id,
          downloaded_event_id: downloaded_event_id,
          wait_attempt: attempt + 1,
          wait_max_attempts: MEDIA_WAIT_MAX_ATTEMPTS,
          next_retry_at: (Time.current + MEDIA_WAIT_SECONDS.seconds).utc.iso8601(3),
          reason: reason.to_s,
          retry_job_id: retry_job&.job_id.to_s.presence
        }.compact
      )
      return
    end

    error = StandardError.new("Story analysis cannot start: #{reason} (downloaded_event_id=#{downloaded_event_id})")
    mark_analysis_status!(
      profile: profile,
      story_id: story_id,
      status: "failed",
      extra: {
        "failed_at" => Time.current.iso8601(3),
        "failure_reason" => reason.to_s,
        "error_class" => error.class.name,
        "error_message" => error.message.to_s.byteslice(0, 280),
        "media_wait_attempt" => attempt,
        "waiting_for_analysis_lock" => false
      }
    )
    record_story_analysis_failed_event(
      profile: profile,
      story_id: story_id,
      error: error,
      reason: reason.to_s,
      downloaded_event_id: downloaded_event_id,
      media_wait_attempt: attempt
    )
    Ops::StructuredLogger.error(
      event: "story_analysis.media_attachment_missing",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        downloaded_event_id: downloaded_event_id,
        wait_attempt: attempt,
        wait_max_attempts: MEDIA_WAIT_MAX_ATTEMPTS,
        reason: reason.to_s
      }
    )
  end

  def handle_story_analysis_lock_busy!(
    account:,
    profile:,
    story_id:,
    story_payload:,
    downloaded_event_id:,
    ingested_story_id:,
    auto_reply:,
    media_wait_attempt:,
    analysis_lock_wait_attempt:
  )
    attempt = analysis_lock_wait_attempt.to_i
    if attempt < ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS
      retry_job = self.class.set(wait: ANALYSIS_LOCK_WAIT_SECONDS.seconds).perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        story_payload: story_payload,
        downloaded_event_id: downloaded_event_id,
        ingested_story_id: ingested_story_id,
        auto_reply: auto_reply,
        media_wait_attempt: media_wait_attempt.to_i,
        analysis_lock_wait_attempt: attempt + 1
      )
      next_retry_at = Time.current + ANALYSIS_LOCK_WAIT_SECONDS.seconds
      mark_analysis_status!(
        profile: profile,
        story_id: story_id,
        status: "queued",
        extra: {
          "status_reason" => "active_story_analysis_running",
          "waiting_for_analysis_lock" => true,
          "analysis_lock_wait_attempt" => attempt + 1,
          "analysis_lock_wait_max_attempts" => ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS,
          "next_retry_at" => next_retry_at.iso8601(3),
          "active_job_id" => retry_job&.job_id.to_s.presence,
          "queue_name" => retry_job&.queue_name.to_s.presence
        }.compact
      )
      Ops::StructuredLogger.info(
        event: "story_analysis.lock_wait_enqueued",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          story_id: story_id,
          lock_wait_attempt: attempt + 1,
          lock_wait_max_attempts: ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS,
          next_retry_at: next_retry_at.utc.iso8601(3),
          retry_job_id: retry_job&.job_id.to_s.presence
        }.compact
      )
      return
    end

    error = StandardError.new("Story analysis lock wait retries exhausted for story_id=#{story_id}")
    mark_analysis_status!(
      profile: profile,
      story_id: story_id,
      status: "failed",
      extra: {
        "failed_at" => Time.current.iso8601(3),
        "failure_reason" => "analysis_lock_wait_timeout",
        "error_class" => error.class.name,
        "error_message" => error.message.to_s.byteslice(0, 280),
        "analysis_lock_wait_attempt" => attempt,
        "analysis_lock_wait_max_attempts" => ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS,
        "waiting_for_analysis_lock" => false
      }
    )
    record_story_analysis_failed_event(
      profile: profile,
      story_id: story_id,
      error: error,
      reason: "analysis_lock_wait_timeout",
      downloaded_event_id: downloaded_event_id
    )
  end

  def claim_story_analysis_lock!(account_id:)
    return true unless postgres_adapter?

    key_a, key_b = story_analysis_lock_keys(account_id: account_id)
    value = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{key_a}, #{key_b})")
    ActiveModel::Type::Boolean.new.cast(value)
  rescue StandardError => e
    Ops::StructuredLogger.warn(
      event: "story_analysis.lock_claim_failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }
    )
    true
  end

  def release_story_analysis_lock!(account_id:)
    return unless postgres_adapter?

    key_a, key_b = story_analysis_lock_keys(account_id: account_id)
    ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{key_a}, #{key_b})")
  rescue StandardError => e
    Ops::StructuredLogger.warn(
      event: "story_analysis.lock_release_failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }
    )
    nil
  end

  def story_analysis_lock_keys(account_id:)
    [ ANALYSIS_LOCK_NAMESPACE, account_id.to_i ]
  end

  def postgres_adapter?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?("postgres")
  rescue StandardError
    false
  end

  def analysis_queue_metadata(profile:, story_id:)
    event = profile.instagram_profile_events.find_by(kind: "story_analysis_queued", external_id: "story_analysis_queued:#{story_id}")
    metadata = event&.metadata
    return metadata.deep_dup if metadata.is_a?(Hash)

    { "story_id" => story_id.to_s }
  rescue StandardError
    { "story_id" => story_id.to_s }
  end

  def mark_analysis_status!(profile:, story_id:, status:, extra:)
    event = profile.instagram_profile_events.find_by(kind: "story_analysis_queued", external_id: "story_analysis_queued:#{story_id}")
    return unless event

    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["status"] = status.to_s
    metadata["status_updated_at"] = Time.current.iso8601(3)
    metadata.merge!(extra.to_h)
    event.update!(metadata: metadata)
  rescue StandardError => e
    Ops::StructuredLogger.warn(
      event: "story_analysis.status_update_failed",
      payload: {
        active_job_id: job_id,
        instagram_profile_id: profile&.id,
        story_id: story_id.to_s,
        attempted_status: status.to_s,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }
    )
    nil
  end

  def record_story_analysis_failed_event(profile:, story_id:, error:, reason: nil, downloaded_event_id: nil, media_wait_attempt: nil)
    base_metadata = analysis_queue_metadata(profile: profile, story_id: story_id)
    profile.record_event!(
      kind: "story_analysis_failed",
      external_id: "story_analysis_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: base_metadata.merge(
        failure_reason: reason.to_s.presence,
        downloaded_event_id: downloaded_event_id,
        media_wait_attempt: media_wait_attempt,
        error_class: error.class.name,
        error_message: error.message.to_s.byteslice(0, 500)
      ).compact
    )
  rescue StandardError
    nil
  end
end
