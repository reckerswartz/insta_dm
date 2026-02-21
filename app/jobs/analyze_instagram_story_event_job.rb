require "net/http"
require "timeout"

class AnalyzeInstagramStoryEventJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:story_analysis)
  AUTO_QUEUE_LLM_COMMENT_ENV_KEY = "STORY_AUTO_QUEUE_LLM_COMMENT".freeze

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
    auto_reply: false
  )
    account = InstagramAccount.find_by(id: instagram_account_id)
    profile = InstagramProfile.find_by(id: instagram_profile_id, instagram_account_id: instagram_account_id)
    return unless account && profile

    sid = story_id.to_s.strip
    return if sid.blank?

    service = analysis_service(account: account, profile: profile)
    story = service.normalized_story_payload(story_payload: story_payload, story_id: sid)
    downloaded_event = profile.instagram_profile_events.find_by(id: downloaded_event_id, kind: "story_downloaded")
    return unless downloaded_event&.media&.attached?

    mark_analysis_status!(profile: profile, story_id: sid, status: "started", extra: { "started_at" => Time.current.iso8601(3) })

    bytes = downloaded_event.media.blob.download.to_s
    content_type = downloaded_event.media.blob.content_type.to_s.presence || "application/octet-stream"
    analysis = service.analyze_story_for_comments(
      story: story,
      analyzable: downloaded_event,
      bytes: bytes,
      content_type: content_type
    )
    unless analysis[:ok]
      mark_analysis_status!(
        profile: profile,
        story_id: sid,
        status: "failed",
        extra: {
          "failed_at" => Time.current.iso8601(3),
          "failure_reason" => "analysis_not_available"
        }
      )
      return
    end

    base_metadata = analysis_queue_metadata(profile: profile, story_id: sid)
    llm_comment_queue = queue_story_comment_generation_if_eligible!(
      event: downloaded_event,
      analysis: analysis
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
        llm_comment_queue_name: llm_comment_queue[:queue_name]
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
        "reply_queued" => reply_queued,
        "reply_decision_reason" => reply_reason.to_s.presence
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
          "error_message" => e.message.to_s.byteslice(0, 280)
        }
      )
      record_story_analysis_failed_event(profile: profile, story_id: sid, error: e)
    end
    raise
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
  rescue StandardError
    nil
  end

  def record_story_analysis_failed_event(profile:, story_id:, error:)
    base_metadata = analysis_queue_metadata(profile: profile, story_id: story_id)
    profile.record_event!(
      kind: "story_analysis_failed",
      external_id: "story_analysis_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: base_metadata.merge(
        error_class: error.class.name,
        error_message: error.message.to_s.byteslice(0, 500)
      )
    )
  rescue StandardError
    nil
  end
end
