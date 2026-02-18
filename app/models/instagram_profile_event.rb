require "digest"

class InstagramProfileEvent < ApplicationRecord
  class LocalStoryIntelligenceUnavailableError < StandardError
    attr_reader :reason, :source

    def initialize(message = nil, reason: nil, source: nil)
      @reason = reason.to_s.presence
      @source = source.to_s.presence
      super(message || "Local story intelligence unavailable")
    end
  end

  belongs_to :instagram_profile

  has_one_attached :media
  has_many :instagram_stories, foreign_key: :source_event_id, dependent: :nullify

  validates :kind, presence: true
  validates :external_id, presence: true
  validates :detected_at, presence: true

  # LLM Comment validations
  validates :llm_comment_provider, inclusion: { in: %w[ollama local], allow_nil: true }
  validates :llm_comment_status, inclusion: { in: %w[not_requested queued running completed failed skipped], allow_nil: true }
  validate :llm_comment_consistency, on: :update

  after_commit :broadcast_account_audit_logs_refresh
  after_commit :broadcast_story_archive_refresh, on: %i[create update]
  after_commit :append_profile_history_narrative, on: :create
  after_commit :broadcast_profile_events_refresh

  STORY_ARCHIVE_EVENT_KINDS = %w[
    story_downloaded
    story_image_downloaded_via_feed
    story_media_downloaded_via_feed
  ].freeze

  LLM_SUCCESS_STATUSES = %w[ok].freeze

  def has_llm_generated_comment?
    llm_generated_comment.present?
  end

  def llm_comment_in_progress?
    %w[queued running].include?(llm_comment_status.to_s)
  end

  def queue_llm_comment_generation!(job_id: nil)
    update!(
      llm_comment_status: "queued",
      llm_comment_job_id: job_id.to_s.presence || llm_comment_job_id,
      llm_comment_last_error: nil
    )

    broadcast_llm_comment_generation_queued(job_id: job_id)
  end

  def mark_llm_comment_running!(job_id: nil)
    update!(
      llm_comment_status: "running",
      llm_comment_job_id: job_id.to_s.presence || llm_comment_job_id,
      llm_comment_attempts: llm_comment_attempts.to_i + 1,
      llm_comment_last_error: nil
    )

    broadcast_llm_comment_generation_start
  end

  def mark_llm_comment_failed!(error:)
    update!(
      llm_comment_status: "failed",
      llm_comment_last_error: error.message.to_s,
      llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
        "last_failure" => {
          "error_class" => error.class.name,
          "error_message" => error.message.to_s,
          "failed_at" => Time.current.iso8601
        }
      )
    )

    broadcast_llm_comment_generation_error(error.message)
  rescue StandardError
    nil
  end

  def mark_llm_comment_skipped!(message:, reason: nil, source: nil)
    intel_status =
      if source.to_s == "validated_story_policy"
        "policy_blocked"
      else
        "unavailable"
      end
    details = {
      "error_class" => "LocalStoryIntelligenceUnavailableError",
      "error_message" => message.to_s,
      "failed_at" => Time.current.iso8601,
      "reason" => reason.to_s.presence,
      "source" => source.to_s.presence
    }.compact

    update!(
      llm_comment_status: "skipped",
      llm_comment_last_error: message.to_s,
      llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
        "last_failure" => details,
        "local_story_intelligence_status" => intel_status
      )
    )

    broadcast_llm_comment_generation_skipped(
      message: message.to_s,
      reason: reason,
      source: source
    )
  rescue StandardError
    nil
  end

  def generate_llm_comment!(provider: :local, model: nil)
    if has_llm_generated_comment?
      update_columns(
        llm_comment_status: "completed",
        llm_comment_last_error: nil,
        updated_at: Time.current
      )

      return {
        status: "already_completed",
        selected_comment: llm_generated_comment,
        relevance_score: llm_comment_relevance_score
      }
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil
    context = build_comment_context
    local_intel = context[:local_story_intelligence].is_a?(Hash) ? context[:local_story_intelligence] : {}
    validated_story_insights = context[:validated_story_insights].is_a?(Hash) ? context[:validated_story_insights] : {}
    generation_policy = validated_story_insights[:generation_policy].is_a?(Hash) ? validated_story_insights[:generation_policy] : {}
    persist_validated_story_insights!(validated_story_insights)
    persist_local_story_intelligence!(local_intel)
    if local_story_intelligence_blank?(local_intel)
      reason = local_intel[:reason].to_s.presence || "local_story_intelligence_blank"
      source = local_intel[:source].to_s.presence || "unknown"
      raise LocalStoryIntelligenceUnavailableError.new(
        "Local story intelligence unavailable (reason: #{reason}, source: #{source}).",
        reason: reason,
        source: source
      )
    end
    unless ActiveModel::Type::Boolean.new.cast(generation_policy[:allow_comment])
      policy_reason_code = generation_policy[:reason_code].to_s.presence || "policy_blocked"
      policy_reason = generation_policy[:reason].to_s.presence || "Comment generation blocked by verified story policy."
      raise LocalStoryIntelligenceUnavailableError.new(
        policy_reason,
        reason: policy_reason_code,
        source: "validated_story_policy"
      )
    end
    broadcast_llm_comment_generation_progress(stage: "context_ready", message: "Context prepared from local story intelligence.", progress: 20)
    technical_details = capture_technical_details(context)
    broadcast_llm_comment_generation_progress(stage: "model_running", message: "Generating suggestions with local model.", progress: 55)

    generator = Ai::LocalEngagementCommentGenerator.new(
      ollama_client: Ai::OllamaClient.new,
      model: model
    )

    result = generator.generate!(
      post_payload: context[:post_payload],
      image_description: context[:image_description],
      topics: context[:topics],
      author_type: context[:author_type],
      historical_comments: context[:historical_comments],
      historical_context: context[:historical_context],
      historical_story_context: context[:historical_story_context],
      local_story_intelligence: context[:local_story_intelligence],
      historical_comparison: context[:historical_comparison],
      cv_ocr_evidence: context[:cv_ocr_evidence],
      verified_story_facts: context[:verified_story_facts],
      story_ownership_classification: context[:story_ownership_classification],
      generation_policy: context[:generation_policy],
      profile_preparation: context[:profile_preparation],
      verified_profile_history: context[:verified_profile_history],
      conversational_voice: context[:conversational_voice]
    )
    enhanced_result = result.merge(technical_details: technical_details)

    unless LLM_SUCCESS_STATUSES.include?(result[:status].to_s)
      raise "Local pipeline did not produce valid model suggestions (fallback blocked): #{result[:error_message]}"
    end

    ranked = Ai::CommentRelevanceScorer.rank(
      suggestions: result[:comment_suggestions],
      image_description: context[:image_description],
      topics: context[:topics],
      historical_comments: context[:historical_comments]
    )

    selected_comment, score = ranked.first
    raise "No valid comment suggestions generated" if selected_comment.to_s.blank?

    duration_ms =
      if started_at
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round
      end

    update!(
      llm_generated_comment: selected_comment,
      llm_comment_generated_at: Time.current,
      llm_comment_model: result[:model],
      llm_comment_provider: provider.to_s,
      llm_comment_status: "completed",
      llm_comment_relevance_score: score,
      llm_comment_last_error: nil,
      llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
        "prompt" => result[:prompt],
        "source" => result[:source],
        "fallback_used" => ActiveModel::Type::Boolean.new.cast(result[:fallback_used]),
        "generation_status" => result[:status],
        "technical_details" => technical_details,
        "local_story_intelligence" => context[:local_story_intelligence],
        "historical_story_context_used" => Array(context[:historical_story_context]).first(12),
        "historical_comparison" => context[:historical_comparison],
        "cv_ocr_evidence" => context[:cv_ocr_evidence],
        "verified_story_facts" => context[:verified_story_facts],
        "ownership_classification" => context[:story_ownership_classification],
        "generation_policy" => context[:generation_policy],
        "validated_story_insights" => context[:validated_story_insights],
        "ranked_candidates" => ranked.first(8).map { |text, value| { "comment" => text, "score" => value } },
        "selected_comment" => selected_comment,
        "selected_relevance_score" => score,
        "generated_at" => Time.current.iso8601,
        "processing_ms" => duration_ms,
        "pipeline" => "validated_story_intelligence_v3"
      )
    )

    broadcast_llm_comment_generation_progress(stage: "completed", message: "Comment ready.", progress: 100)
    broadcast_story_archive_refresh
    broadcast_llm_comment_generation_update(
      enhanced_result.merge(
        selected_comment: selected_comment,
        relevance_score: score,
        ranked_candidates: ranked.first(8)
      )
    )

    enhanced_result.merge(
      selected_comment: selected_comment,
      relevance_score: score,
      ranked_candidates: ranked.first(8)
    )
  end

  def reply_comment
    metadata["reply_comment"] if metadata.is_a?(Hash)
  end

  def story_archive_item?
    STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)
  end

  def capture_technical_details(context)
    profile = instagram_profile
    media_blob = media.attached? ? media.blob : nil
    timeline = story_timeline_data
    local_intelligence = context[:local_story_intelligence].is_a?(Hash) ? context[:local_story_intelligence] : {}
    verified_story_facts = context[:verified_story_facts].is_a?(Hash) ? context[:verified_story_facts] : {}
    story_ownership_classification = context[:story_ownership_classification].is_a?(Hash) ? context[:story_ownership_classification] : {}
    generation_policy = context[:generation_policy].is_a?(Hash) ? context[:generation_policy] : {}
    validated_story_insights = context[:validated_story_insights].is_a?(Hash) ? context[:validated_story_insights] : {}
    profile_preparation = context[:profile_preparation].is_a?(Hash) ? context[:profile_preparation] : {}
    verified_profile_history = Array(context[:verified_profile_history]).first(12)
    conversational_voice = context[:conversational_voice].is_a?(Hash) ? context[:conversational_voice] : {}

    {
      timestamp: Time.current.iso8601,
      event_id: id,
      story_id: metadata.is_a?(Hash) ? metadata["story_id"] : nil,
      timeline: timeline,
      media_info: media_blob ? {
        content_type: media_blob.content_type,
        size_bytes: media_blob.byte_size,
        dimensions: metadata.is_a?(Hash) ? metadata.slice("media_width", "media_height") : {},
        url: Rails.application.routes.url_helpers.rails_blob_path(media, only_path: true)
      } : {},
      local_story_intelligence: local_intelligence,
      analysis: {
        verified_story_facts: verified_story_facts,
        ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        validated_story_insights: validated_story_insights,
        cv_ocr_evidence: context[:cv_ocr_evidence],
        historical_comparison: context[:historical_comparison],
        extraction_summary: {
          has_ocr_text: verified_story_facts[:ocr_text].to_s.present?,
          has_transcript: verified_story_facts[:transcript].to_s.present?,
          objects_count: Array(verified_story_facts[:objects]).size,
          object_detections_count: Array(verified_story_facts[:object_detections]).size,
          scenes_count: Array(verified_story_facts[:scenes]).size,
          hashtags_count: Array(verified_story_facts[:hashtags]).size,
          mentions_count: Array(verified_story_facts[:mentions]).size,
          detected_usernames_count: Array(verified_story_facts[:detected_usernames]).size,
          faces_count: verified_story_facts[:face_count].to_i,
          signal_score: verified_story_facts[:signal_score].to_i,
          source: verified_story_facts[:source].to_s,
          reason: verified_story_facts[:reason].to_s.presence
        }
      },
      profile_analysis: {
        username: profile&.username,
        display_name: profile&.display_name,
        bio: profile&.bio,
        bio_length: profile&.bio&.length || 0,
        detected_author_type: determine_author_type(profile),
        extracted_topics: extract_topics_from_profile(profile),
        profile_comment_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        verified_profile_history: verified_profile_history
      },
      prompt_engineering: {
        final_prompt: context[:post_payload],
        image_description: context[:image_description],
        topics_used: context[:topics],
        author_classification: context[:author_type],
        historical_context: context[:historical_context],
        historical_story_context: Array(context[:historical_story_context]).first(10),
        historical_comparison: context[:historical_comparison],
        verified_story_facts: verified_story_facts,
        ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        cv_ocr_evidence: context[:cv_ocr_evidence],
        profile_comment_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        verified_profile_history: verified_profile_history,
        rules_applied: context[:post_payload]&.dig(:rules)
      }
    }
  end

  def broadcast_llm_comment_generation_queued(job_id: nil)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "queued",
        job_id: job_id.to_s.presence || llm_comment_job_id,
        message: "Comment generation queued",
        estimated_seconds: estimated_generation_seconds(queue_state: true),
        progress: 5
      }
    )
  rescue StandardError
    nil
  end

  def broadcast_llm_comment_generation_update(generation_result)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "completed",
        comment: llm_generated_comment,
        generated_at: llm_comment_generated_at,
        model: llm_comment_model,
        provider: llm_comment_provider,
        relevance_score: llm_comment_relevance_score,
        generation_result: generation_result
      }
    )
  rescue StandardError
    nil
  end

  def broadcast_llm_comment_generation_start
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "started",
        message: "Generating comment...",
        estimated_seconds: estimated_generation_seconds(queue_state: false),
        progress: 12
      }
    )
  rescue StandardError
    nil
  end

  def broadcast_llm_comment_generation_error(error_message)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "error",
        error: error_message,
        message: "Failed to generate comment"
      }
    )
  rescue StandardError
    nil
  end

  def broadcast_llm_comment_generation_skipped(message:, reason: nil, source: nil)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "skipped",
        message: message.to_s.presence || "Comment generation skipped",
        reason: reason.to_s.presence,
        source: source.to_s.presence
      }.compact
    )
  rescue StandardError
    nil
  end

  def broadcast_llm_comment_generation_progress(stage:, message:, progress:)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: "running",
        stage: stage.to_s,
        message: message.to_s,
        progress: progress.to_i.clamp(0, 100),
        estimated_seconds: estimated_generation_seconds(queue_state: false)
      }
    )
  rescue StandardError
    nil
  end

  def self.broadcast_story_archive_refresh!(account:)
    return unless account

    Turbo::StreamsChannel.broadcast_replace_to(
      [account, :story_archive],
      target: "story_media_archive_refresh_signal",
      partial: "instagram_accounts/story_archive_refresh_signal",
      locals: { refreshed_at: Time.current }
    )
  rescue StandardError
    nil
  end

  private

  def broadcast_account_audit_logs_refresh
    account = instagram_profile&.instagram_account
    return unless account

    entries = Ops::AuditLogBuilder.for_account(instagram_account: account, limit: 120)
    Turbo::StreamsChannel.broadcast_replace_to(
      account,
      target: "account_audit_logs_section",
      partial: "instagram_accounts/audit_logs_section",
      locals: { recent_audit_entries: entries }
    )
  rescue StandardError
    nil
  end

  def append_profile_history_narrative
    Ai::ProfileHistoryNarrativeBuilder.append_event!(self)
  rescue StandardError
    nil
  end

  def broadcast_story_archive_refresh
    return unless STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)

    account = instagram_profile&.instagram_account
    self.class.broadcast_story_archive_refresh!(account: account)
  rescue StandardError
    nil
  end

  def broadcast_profile_events_refresh
    account_id = instagram_profile&.instagram_account_id
    return unless account_id

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "profile_events_changed",
      account_id: account_id,
      payload: { profile_id: instagram_profile_id, event_id: id },
      throttle_key: "profile_events_changed:#{instagram_profile_id}"
    )
  rescue StandardError
    nil
  end

  def llm_comment_consistency
    status = llm_comment_status.to_s

    if status == "completed" && llm_generated_comment.blank?
      errors.add(:llm_generated_comment, "must be present when status is completed")
    end

    if status == "completed" && llm_comment_generated_at.blank?
      errors.add(:llm_comment_generated_at, "must be present when status is completed")
    end

    if status == "completed" && llm_comment_provider.blank?
      errors.add(:llm_comment_provider, "must be present when status is completed")
    end

    if llm_generated_comment.blank? && llm_comment_generated_at.present?
      errors.add(:llm_generated_comment, "must be present when generated_at is set")
    end
  end

  def build_comment_context
    profile = instagram_profile
    raw_metadata = metadata.is_a?(Hash) ? metadata : {}
    local_story_intelligence = local_story_intelligence_payload
    validated_story_insights = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: local_story_intelligence,
      metadata: raw_metadata
    ).build
    verified_story_facts = validated_story_insights[:verified_story_facts].is_a?(Hash) ? validated_story_insights[:verified_story_facts] : {}

    post_payload = {
      post: {
        event_id: id,
        media_type: raw_metadata["media_type"].to_s.presence || media&.blob&.content_type.to_s.presence || "unknown"
      },
      author_profile: {
        username: profile&.username,
        display_name: profile&.display_name,
        bio_keywords: extract_topics_from_profile(profile).first(10)
      },
      rules: {
        max_length: 140,
        require_local_pipeline: true,
        require_verified_story_facts: true,
        block_unverified_generation: true,
        verified_only: true
      }
    }

    image_description = build_story_image_description(local_story_intelligence: verified_story_facts.presence || local_story_intelligence)

    historical_comments = recent_llm_comments_for_profile(profile)
    topics = (Array(verified_story_facts[:topics]) + extract_topics_from_profile(profile)).map(&:to_s).reject(&:blank?).uniq.first(20)
    historical_story_context = recent_story_intelligence_context(profile)
    profile_preparation = latest_profile_comment_preparation(profile)
    verified_profile_history = recent_analyzed_profile_history(profile)
    conversational_voice = build_conversational_voice_profile(
      profile: profile,
      historical_story_context: historical_story_context,
      verified_profile_history: verified_profile_history,
      profile_preparation: profile_preparation
    )
    historical_comparison = build_historical_comparison(
      current: verified_story_facts.presence || local_story_intelligence,
      historical_story_context: historical_story_context
    )
    validated_story_insights = apply_historical_validation(
      validated_story_insights: validated_story_insights,
      historical_comparison: historical_comparison
    )
    story_ownership_classification = validated_story_insights[:ownership_classification].is_a?(Hash) ? validated_story_insights[:ownership_classification] : {}
    generation_policy = validated_story_insights[:generation_policy].is_a?(Hash) ? validated_story_insights[:generation_policy] : {}
    cv_ocr_evidence = build_cv_ocr_evidence(local_story_intelligence: verified_story_facts.presence || local_story_intelligence)

    post_payload[:historical_comparison] = historical_comparison
    post_payload[:cv_ocr_evidence] = cv_ocr_evidence
    post_payload[:story_ownership_classification] = story_ownership_classification
    post_payload[:generation_policy] = generation_policy
    post_payload[:profile_comment_preparation] = profile_preparation
    post_payload[:conversational_voice] = conversational_voice
    post_payload[:verified_profile_history] = verified_profile_history
    historical_context = build_compact_historical_context(
      profile: profile,
      historical_story_context: historical_story_context,
      verified_profile_history: verified_profile_history,
      profile_preparation: profile_preparation
    )

    {
      post_payload: post_payload,
      image_description: image_description,
      topics: topics,
      author_type: determine_author_type(profile),
      historical_comments: historical_comments,
      historical_context: historical_context,
      historical_story_context: historical_story_context,
      historical_comparison: historical_comparison,
      cv_ocr_evidence: cv_ocr_evidence,
      local_story_intelligence: local_story_intelligence,
      verified_story_facts: verified_story_facts,
      story_ownership_classification: story_ownership_classification,
      generation_policy: generation_policy,
      validated_story_insights: validated_story_insights,
      profile_preparation: profile_preparation,
      verified_profile_history: verified_profile_history,
      conversational_voice: conversational_voice
    }
  end

  def local_story_intelligence_payload
    raw = metadata.is_a?(Hash) ? metadata : {}
    story = instagram_stories.order(updated_at: :desc, id: :desc).first
    story_meta = story&.metadata.is_a?(Hash) ? story.metadata : {}
    story_embedded = story_meta["content_understanding"].is_a?(Hash) ? story_meta["content_understanding"] : {}
    event_embedded = raw["local_story_intelligence"].is_a?(Hash) ? raw["local_story_intelligence"] : {}
    embedded = story_embedded.presence || event_embedded.presence || {}

    ocr_text = first_present(
      embedded["ocr_text"],
      event_embedded["ocr_text"],
      story_meta["ocr_text"],
      raw["ocr_text"]
    )
    transcript = first_present(
      embedded["transcript"],
      event_embedded["transcript"],
      story_meta["transcript"],
      raw["transcript"]
    )
    objects = merge_unique_values(
      embedded["objects"],
      event_embedded["objects"],
      story_meta["content_signals"],
      raw["content_signals"]
    )
    hashtags = merge_unique_values(
      embedded["hashtags"],
      event_embedded["hashtags"],
      story_meta["hashtags"],
      raw["hashtags"]
    )
    mentions = merge_unique_values(
      embedded["mentions"],
      event_embedded["mentions"],
      story_meta["mentions"],
      raw["mentions"]
    )
    profile_handles = merge_unique_values(
      embedded["profile_handles"],
      event_embedded["profile_handles"],
      story_meta["profile_handles"],
      raw["profile_handles"]
    )
    scenes = normalize_hash_array(
      embedded["scenes"],
      event_embedded["scenes"],
      story_meta["scenes"],
      raw["scenes"]
    )
    ocr_blocks = normalize_hash_array(
      embedded["ocr_blocks"],
      event_embedded["ocr_blocks"],
      story_meta["ocr_blocks"],
      raw["ocr_blocks"]
    )
    ocr_text_from_blocks = ocr_blocks
      .map { |row| row.is_a?(Hash) ? (row["text"] || row[:text]) : nil }
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .join("\n")
      .presence
    ocr_text = first_present(ocr_text, ocr_text_from_blocks)
    if hashtags.empty? && ocr_text.to_s.present?
      hashtags = ocr_text.to_s.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(20)
    end
    if mentions.empty? && ocr_text.to_s.present?
      mentions = ocr_text.to_s.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(20)
    end
    if profile_handles.empty? && ocr_text.to_s.present?
      profile_handles = ocr_text.to_s.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
        .map(&:downcase)
        .select { |token| token.include?("_") || token.include?(".") }
        .reject { |token| token.include?("instagram.com") }
        .uniq
        .first(30)
    end
    object_detections = normalize_hash_array(
      embedded["object_detections"],
      event_embedded["object_detections"],
      story_meta["object_detections"],
      raw["object_detections"]
    )
    detected_object_labels = object_detections
      .map { |row| row.is_a?(Hash) ? (row[:label] || row["label"] || row[:description] || row["description"]) : nil }
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
    objects = merge_unique_values(objects, detected_object_labels)
    topics = merge_unique_values(
      embedded["topics"],
      objects,
      hashtags.map { |tag| tag.to_s.delete_prefix("#") }
    )

    normalized_people = normalize_people_rows(
      event_embedded["people"],
      raw["face_people"],
      raw["people"],
      story_meta["face_people"],
      story_meta["participants"],
      story_meta.dig("face_identity", "participants"),
      raw["participants"],
      raw.dig("face_identity", "participants")
    )
    computed_face_count = [
      (event_embedded["face_count"] || embedded["faces_count"] || raw["face_count"]).to_i,
      normalized_people.size
    ].max

    payload = {
      ocr_text: ocr_text.to_s.presence,
      transcript: transcript.to_s.presence,
      objects: objects,
      hashtags: hashtags,
      mentions: mentions,
      profile_handles: profile_handles,
      topics: topics,
      scenes: scenes.first(80),
      ocr_blocks: ocr_blocks.first(120),
      object_detections: normalize_object_detections(object_detections, limit: 120),
      face_count: computed_face_count,
      people: normalized_people.first(12),
      source_account_reference: extract_source_account_reference(raw: raw, story_meta: story_meta),
      source_profile_ids: extract_source_profile_ids_from_metadata(raw: raw, story_meta: story_meta),
      media_type: raw["media_type"].to_s.presence || story_meta["media_type"].to_s.presence || media&.blob&.content_type.to_s.presence,
      source: if story_embedded.present?
        "story_processing"
      elsif event_embedded.present?
        "event_local_pipeline"
      else
        "event_metadata"
      end
    }

    needs_structured_enrichment =
      media.attached? &&
      Array(payload[:object_detections]).empty? &&
      Array(payload[:ocr_blocks]).empty? &&
      Array(payload[:scenes]).empty?

    if needs_structured_enrichment
      extracted = extract_live_local_intelligence_from_event_media(story_id: raw["story_id"].to_s.presence || id.to_s)
      if extracted.is_a?(Hash)
        merged_scenes = normalize_hash_array(payload[:scenes], extracted[:scenes]).first(80)
        merged_ocr_blocks = normalize_hash_array(payload[:ocr_blocks], extracted[:ocr_blocks]).first(120)
        merged_object_detections = normalize_object_detections(payload[:object_detections], extracted[:object_detections], limit: 120)

        payload[:scenes] = merged_scenes
        payload[:ocr_blocks] = merged_ocr_blocks
        payload[:object_detections] = merged_object_detections

        if merged_scenes.any? || merged_ocr_blocks.any? || merged_object_detections.any?
          payload[:source] = "live_local_enrichment"
        end
      end
    end

    if local_story_intelligence_blank?(payload) && media.attached?
      extracted = extract_live_local_intelligence_from_event_media(story_id: raw["story_id"].to_s.presence || id.to_s)
      if extracted.is_a?(Hash)
        if !local_story_intelligence_blank?(extracted)
          payload = extracted
        elsif extracted[:reason].to_s.present?
          payload[:reason] = extracted[:reason].to_s
        end
      end
    end

    if local_story_intelligence_blank?(payload)
      payload[:source] = "unavailable"
      payload[:reason] = payload[:reason].to_s.presence || "local_ai_extraction_empty"
    end

    payload
  rescue StandardError
    {
      ocr_text: nil,
      transcript: nil,
      objects: [],
      hashtags: [],
      mentions: [],
      profile_handles: [],
      topics: [],
      scenes: [],
      ocr_blocks: [],
      object_detections: [],
      source: "unavailable"
    }
  end

  def persist_local_story_intelligence!(payload)
    return unless payload.is_a?(Hash)
    source = payload[:source].to_s
    return if source.blank? || source == "unavailable"

    current_meta = metadata.is_a?(Hash) ? metadata.deep_dup : {}
    current_intel = current_meta["local_story_intelligence"].is_a?(Hash) ? current_meta["local_story_intelligence"] : {}

    current_meta["ocr_text"] = payload[:ocr_text].to_s if payload[:ocr_text].present?
    current_meta["transcript"] = payload[:transcript].to_s if payload[:transcript].present?
    current_meta["content_signals"] = Array(payload[:objects]).map(&:to_s).reject(&:blank?).first(40)
    current_meta["hashtags"] = Array(payload[:hashtags]).map(&:to_s).reject(&:blank?).first(20)
    current_meta["mentions"] = Array(payload[:mentions]).map(&:to_s).reject(&:blank?).first(20)
    current_meta["profile_handles"] = Array(payload[:profile_handles]).map(&:to_s).reject(&:blank?).first(30)
    current_meta["topics"] = Array(payload[:topics]).map(&:to_s).reject(&:blank?).first(40)
    current_meta["scenes"] = normalize_hash_array(payload[:scenes]).first(80)
    current_meta["ocr_blocks"] = normalize_hash_array(payload[:ocr_blocks]).first(120)
    current_meta["object_detections"] = normalize_object_detections(payload[:object_detections], limit: 120)
    current_meta["face_count"] = payload[:face_count].to_i if payload[:face_count].to_i.positive?
    current_meta["face_people"] = Array(payload[:people]).first(12) if Array(payload[:people]).any?
    current_meta["local_story_intelligence"] = {
      "source" => source,
      "captured_at" => Time.current.iso8601,
      "ocr_text" => payload[:ocr_text].to_s.presence,
      "transcript" => payload[:transcript].to_s.presence,
      "objects" => Array(payload[:objects]).first(40),
      "hashtags" => Array(payload[:hashtags]).first(30),
      "mentions" => Array(payload[:mentions]).first(30),
      "profile_handles" => Array(payload[:profile_handles]).first(30),
      "topics" => Array(payload[:topics]).first(40),
      "scenes" => normalize_hash_array(payload[:scenes]).first(80),
      "ocr_blocks" => normalize_hash_array(payload[:ocr_blocks]).first(120),
      "object_detections" => normalize_object_detections(payload[:object_detections], limit: 120),
      "face_count" => payload[:face_count].to_i,
      "people" => Array(payload[:people]).first(12)
    }
    current_meta["local_story_intelligence_history_appended_at"] = Time.current.iso8601

    update_columns(metadata: current_meta, updated_at: Time.current)
    ownership = current_meta["story_ownership_classification"].is_a?(Hash) ? current_meta["story_ownership_classification"] : {}
    policy = current_meta["story_generation_policy"].is_a?(Hash) ? current_meta["story_generation_policy"] : {}
    return if story_excluded_from_narrative?(ownership: ownership, policy: policy)

    history_payload = payload.merge(description: build_story_image_description(local_story_intelligence: payload))
    Ai::ProfileHistoryNarrativeBuilder.append_story_intelligence!(self, intelligence: history_payload)
  rescue StandardError
    nil
  end

  def persist_validated_story_insights!(payload)
    return unless payload.is_a?(Hash)
    verified_story_facts = payload[:verified_story_facts].is_a?(Hash) ? payload[:verified_story_facts] : {}
    ownership_classification = payload[:ownership_classification].is_a?(Hash) ? payload[:ownership_classification] : {}
    generation_policy = payload[:generation_policy].is_a?(Hash) ? payload[:generation_policy] : {}
    return if verified_story_facts.blank? && ownership_classification.blank? && generation_policy.blank?

    signature_payload = {
      verified_story_facts: build_cv_ocr_evidence(local_story_intelligence: verified_story_facts),
      ownership_classification: ownership_classification,
      generation_policy: generation_policy
    }
    signature = Digest::SHA256.hexdigest(signature_payload.to_json)

    current_meta = metadata.is_a?(Hash) ? metadata.deep_dup : {}
    stored = current_meta["validated_story_insights"].is_a?(Hash) ? current_meta["validated_story_insights"] : {}
    return if stored["signature"].to_s == signature

    current_meta["validated_story_insights"] = {
      "signature" => signature,
      "validated_at" => Time.current.iso8601,
      "verified_story_facts" => verified_story_facts,
      "ownership_classification" => ownership_classification,
      "generation_policy" => generation_policy
    }
    current_meta["story_ownership_classification"] = ownership_classification
    current_meta["story_generation_policy"] = generation_policy
    current_meta["detected_external_usernames"] = Array(ownership_classification[:detected_external_usernames] || ownership_classification["detected_external_usernames"]).map(&:to_s).first(12)
    source_profile_references = Array(ownership_classification[:source_profile_references] || ownership_classification["source_profile_references"] || verified_story_facts[:source_profile_references] || verified_story_facts["source_profile_references"]).map(&:to_s).reject(&:blank?).first(20)
    source_profile_ids = Array(ownership_classification[:source_profile_ids] || ownership_classification["source_profile_ids"] || verified_story_facts[:source_profile_ids] || verified_story_facts["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(20)
    share_status = (ownership_classification[:share_status] || ownership_classification["share_status"]).to_s.presence || "unknown"
    allow_comment_value = if generation_policy.key?(:allow_comment)
      generation_policy[:allow_comment]
    else
      generation_policy["allow_comment"]
    end
    excluded_from_narrative = story_excluded_from_narrative?(ownership: ownership_classification, policy: generation_policy)
    current_meta["source_profile_references"] = source_profile_references
    current_meta["source_profile_ids"] = source_profile_ids
    current_meta["share_status"] = share_status
    current_meta["analysis_excluded"] = excluded_from_narrative
    current_meta["analysis_exclusion_reason"] = if excluded_from_narrative
      ownership_classification[:summary].to_s.presence || ownership_classification["summary"].to_s.presence || generation_policy[:reason].to_s.presence || generation_policy["reason"].to_s.presence
    end
    current_meta["content_classification"] = {
      "share_status" => share_status,
      "ownership_label" => ownership_classification[:label] || ownership_classification["label"],
      "allow_comment" => ActiveModel::Type::Boolean.new.cast(allow_comment_value),
      "source_profile_references" => source_profile_references,
      "source_profile_ids" => source_profile_ids
    }
    update_columns(metadata: current_meta, updated_at: Time.current)

    return if excluded_from_narrative

    history_payload = verified_story_facts.merge(
      ownership_classification: ownership_classification[:label] || ownership_classification["label"],
      ownership_summary: ownership_classification[:summary] || ownership_classification["summary"],
      ownership_confidence: ownership_classification[:confidence] || ownership_classification["confidence"],
      ownership_reason_codes: Array(ownership_classification[:reason_codes] || ownership_classification["reason_codes"]).first(12),
      generation_policy: generation_policy,
      description: build_story_image_description(local_story_intelligence: verified_story_facts)
    )
    Ai::ProfileHistoryNarrativeBuilder.append_story_intelligence!(self, intelligence: history_payload)
  rescue StandardError
    nil
  end

  def build_story_image_description(local_story_intelligence:)
    signals = Array(local_story_intelligence[:objects]).first(6)
    if signals.empty?
      signals = Array(local_story_intelligence[:object_detections])
        .map { |row| row.is_a?(Hash) ? (row[:label] || row["label"]) : nil }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .first(6)
    end
    ocr = local_story_intelligence[:ocr_text].to_s.strip
    transcript = local_story_intelligence[:transcript].to_s.strip
    topic_text = Array(local_story_intelligence[:topics]).first(5).join(", ")
    scene_count = Array(local_story_intelligence[:scenes]).length
    face_count = local_story_intelligence[:face_count].to_i

    parts = []
    parts << "Detected visual signals: #{signals.join(', ')}." if signals.any?
    parts << "Detected scene transitions: #{scene_count}." if scene_count.positive?
    parts << "Detected faces: #{face_count}." if face_count.positive?
    parts << "OCR text: #{ocr}." if ocr.present?
    parts << "Audio transcript: #{transcript}." if transcript.present?
    parts << "Inferred topics: #{topic_text}." if topic_text.present?
    parts << "Story media context extracted from local AI pipeline." if parts.empty?
    parts.join(" ")
  end

  def first_present(*values)
    values.each do |value|
      text = value.to_s.strip
      return text if text.present?
    end
    nil
  end

  def merge_unique_values(*values)
    values.flat_map { |value| Array(value) }
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .first(40)
  end

  def apply_historical_validation(validated_story_insights:, historical_comparison:)
    insights = validated_story_insights.is_a?(Hash) ? validated_story_insights.deep_dup : {}
    ownership = insights[:ownership_classification].is_a?(Hash) ? insights[:ownership_classification] : {}
    policy = insights[:generation_policy].is_a?(Hash) ? insights[:generation_policy] : {}

    has_overlap = ActiveModel::Type::Boolean.new.cast(historical_comparison[:has_historical_overlap])
    external_usernames = Array(ownership[:detected_external_usernames]).map(&:to_s).reject(&:blank?)
    if ownership[:label].to_s == "owned_by_profile" && !has_overlap && external_usernames.any?
      ownership[:label] = "third_party_content"
      ownership[:decision] = "skip_comment"
      ownership[:reason_codes] = Array(ownership[:reason_codes]) + [ "no_historical_overlap_with_external_usernames" ]
      ownership[:summary] = "Detected external usernames without historical overlap; classified as third-party content."
      policy[:allow_comment] = false
      policy[:reason_code] = "no_historical_overlap_with_external_usernames"
      policy[:reason] = ownership[:summary]
      policy[:classification] = ownership[:label]
    end
    policy[:historical_overlap] = has_overlap

    insights[:ownership_classification] = ownership
    insights[:generation_policy] = policy
    insights
  rescue StandardError
    validated_story_insights
  end

  def local_story_intelligence_blank?(payload)
    return true unless payload.is_a?(Hash)

    payload[:ocr_text].to_s.strip.blank? &&
      payload[:transcript].to_s.strip.blank? &&
      Array(payload[:objects]).empty? &&
      Array(payload[:object_detections]).empty? &&
      Array(payload[:ocr_blocks]).empty? &&
      Array(payload[:scenes]).empty? &&
      Array(payload[:hashtags]).empty? &&
      Array(payload[:mentions]).empty? &&
      Array(payload[:profile_handles]).empty? &&
      Array(payload[:topics]).empty? &&
      payload[:face_count].to_i <= 0 &&
      Array(payload[:people]).empty?
  end

  def extract_live_local_intelligence_from_event_media(story_id:)
    content_type = media&.blob&.content_type.to_s
    return {} if content_type.blank?

    if content_type.start_with?("image/")
      extract_local_intelligence_from_image_bytes(image_bytes: media.download, story_id: story_id)
    elsif content_type.start_with?("video/")
      extract_local_intelligence_from_video_bytes(video_bytes: media.download, story_id: story_id, content_type: content_type)
    else
      {}
    end
  rescue StandardError
    {}
  end

  def extract_local_intelligence_from_image_bytes(image_bytes:, story_id:)
    detection = FaceDetectionService.new.detect(
      media_payload: { story_id: story_id.to_s, image_bytes: image_bytes }
    )
    understanding = StoryContentUnderstandingService.new.build(
      media_type: "image",
      detections: [detection],
      transcript_text: nil
    )
    people = resolve_people_from_faces(detected_faces: Array(detection[:faces]), fallback_image_bytes: image_bytes, story_id: story_id)

    {
      ocr_text: understanding[:ocr_text].to_s.presence,
      transcript: understanding[:transcript].to_s.presence,
      objects: Array(understanding[:objects]).map(&:to_s).reject(&:blank?).uniq.first(30),
      hashtags: Array(understanding[:hashtags]).map(&:to_s).reject(&:blank?).uniq.first(20),
      mentions: Array(understanding[:mentions]).map(&:to_s).reject(&:blank?).uniq.first(20),
      profile_handles: Array(understanding[:profile_handles]).map(&:to_s).reject(&:blank?).uniq.first(30),
      topics: Array(understanding[:topics]).map(&:to_s).reject(&:blank?).uniq.first(30),
      scenes: Array(understanding[:scenes]).first(80),
      ocr_blocks: Array(understanding[:ocr_blocks]).first(120),
      object_detections: normalize_object_detections(understanding[:object_detections], limit: 120),
      face_count: Array(detection[:faces]).length,
      people: people,
      reason: detection.dig(:metadata, :reason).to_s.presence,
      source: "live_local_vision_ocr"
    }
  end

  def extract_local_intelligence_from_video_bytes(video_bytes:, story_id:, content_type:)
    frame_result = VideoFrameExtractionService.new.extract(
      video_bytes: video_bytes,
      story_id: story_id.to_s,
      content_type: content_type.to_s
    )
    detections = []
    faces = []

    Array(frame_result[:frames]).first(8).each do |frame|
      detection = FaceDetectionService.new.detect(
        media_payload: { story_id: story_id.to_s, image_bytes: frame[:image_bytes] }
      )
      detections << detection
      Array(detection[:faces]).each { |face| faces << face.merge(image_bytes: frame[:image_bytes]) }
    end

    audio_result = VideoAudioExtractionService.new.extract(
      video_bytes: video_bytes,
      story_id: story_id.to_s,
      content_type: content_type.to_s
    )
    transcript = SpeechTranscriptionService.new.transcribe(
      audio_bytes: audio_result[:audio_bytes],
      story_id: story_id.to_s
    )
    video_intel = Ai::LocalMicroserviceClient.new.analyze_video_story_intelligence!(
      video_bytes: video_bytes,
      sample_rate: 2,
      usage_context: { workflow: "story_processing", story_id: story_id.to_s }
    ) rescue {}

    understanding = StoryContentUnderstandingService.new.build(
      media_type: "video",
      detections: detections,
      transcript_text: transcript[:transcript]
    )

    people = resolve_people_from_faces(
      detected_faces: faces,
      fallback_image_bytes: faces.first&.dig(:image_bytes),
      story_id: story_id
    )

    {
      ocr_text: understanding[:ocr_text].to_s.presence,
      transcript: understanding[:transcript].to_s.presence,
      objects: Array(understanding[:objects]).map(&:to_s).reject(&:blank?).uniq.first(40),
      hashtags: Array(understanding[:hashtags]).map(&:to_s).reject(&:blank?).uniq.first(25),
      mentions: Array(understanding[:mentions]).map(&:to_s).reject(&:blank?).uniq.first(25),
      profile_handles: Array(understanding[:profile_handles]).map(&:to_s).reject(&:blank?).uniq.first(40),
      topics: Array(understanding[:topics]).map(&:to_s).reject(&:blank?).uniq.first(40),
      scenes: normalize_hash_array(understanding[:scenes], video_intel["scenes"]).first(80),
      ocr_blocks: normalize_hash_array(understanding[:ocr_blocks], video_intel["ocr_blocks"]).first(120),
      object_detections: normalize_object_detections(understanding[:object_detections], video_intel["object_detections"], limit: 120),
      face_count: faces.length,
      people: people,
      reason: [ frame_result.dig(:metadata, :reason), audio_result.dig(:metadata, :reason), transcript.dig(:metadata, :reason) ]
        .map(&:to_s)
        .reject(&:blank?)
        .uniq
        .join(", ")
        .presence,
      source: "live_local_video_vision_ocr_transcript"
    }
  end

  def resolve_people_from_faces(detected_faces:, fallback_image_bytes:, story_id:)
    account = instagram_profile&.instagram_account
    profile = instagram_profile
    return [] unless account && profile

    embedding_service = FaceEmbeddingService.new
    matcher = VectorMatchingService.new
    Array(detected_faces).first(5).filter_map do |face|
      candidate_image_bytes = face[:image_bytes].presence || fallback_image_bytes
      next if candidate_image_bytes.blank?

      vector_payload = embedding_service.embed(
        media_payload: { story_id: story_id.to_s, media_type: "image", image_bytes: candidate_image_bytes },
        face: face
      )
      vector = Array(vector_payload[:vector]).map(&:to_f)
      next if vector.empty?

      match = matcher.match_or_create!(
        account: account,
        profile: profile,
        embedding: vector,
        occurred_at: occurred_at || detected_at || Time.current
      )
      person = match[:person]
      update_person_face_attributes_for_event!(person: person, face: face)
      {
        person_id: person.id,
        role: match[:role].to_s,
        label: person.label.to_s.presence,
        similarity: match[:similarity],
        age: face[:age],
        age_range: face[:age_range],
        gender: face[:gender],
        gender_score: face[:gender_score].to_f
      }.compact
    end
  rescue StandardError
    []
  end

  def update_person_face_attributes_for_event!(person:, face:)
    return unless person

    metadata = person.metadata.is_a?(Hash) ? person.metadata.deep_dup : {}
    attrs = metadata["face_attributes"].is_a?(Hash) ? metadata["face_attributes"].deep_dup : {}

    gender = face[:gender].to_s.strip.downcase
    if gender.present?
      gender_counts = attrs["gender_counts"].is_a?(Hash) ? attrs["gender_counts"].deep_dup : {}
      gender_counts[gender] = gender_counts[gender].to_i + 1
      attrs["gender_counts"] = gender_counts
      attrs["primary_gender_cue"] = gender_counts.max_by { |_key, count| count.to_i }&.first
    end

    age_range = face[:age_range].to_s.strip
    if age_range.present?
      age_counts = attrs["age_range_counts"].is_a?(Hash) ? attrs["age_range_counts"].deep_dup : {}
      age_counts[age_range] = age_counts[age_range].to_i + 1
      attrs["age_range_counts"] = age_counts
      attrs["primary_age_range"] = age_counts.max_by { |_key, count| count.to_i }&.first
    end

    age_value = face[:age].to_f
    if age_value.positive?
      samples = Array(attrs["age_samples"]).map(&:to_f).first(19)
      samples << age_value.round(1)
      attrs["age_samples"] = samples
      attrs["age_estimate"] = (samples.sum / samples.length.to_f).round(1)
    end

    attrs["last_observed_at"] = Time.current.iso8601
    metadata["face_attributes"] = attrs
    person.update_columns(metadata: metadata, updated_at: Time.current)
  rescue StandardError
    nil
  end

  def recent_story_intelligence_context(profile)
    return [] unless profile

    profile.instagram_profile_events
      .where(kind: STORY_ARCHIVE_EVENT_KINDS)
      .order(detected_at: :desc, id: :desc)
      .limit(18)
      .map do |event|
        meta = event.metadata.is_a?(Hash) ? event.metadata : {}
        intel = meta["local_story_intelligence"].is_a?(Hash) ? meta["local_story_intelligence"] : {}
        objects = merge_unique_values(intel["objects"], meta["content_signals"]).first(8)
        hashtags = merge_unique_values(intel["hashtags"], meta["hashtags"]).first(8)
        mentions = merge_unique_values(intel["mentions"], meta["mentions"]).first(6)
        profile_handles = merge_unique_values(intel["profile_handles"], meta["profile_handles"]).first(8)
        topics = merge_unique_values(intel["topics"], meta["topics"]).first(8)
        ocr_text = first_present(intel["ocr_text"], meta["ocr_text"])
        transcript = first_present(intel["transcript"], meta["transcript"])
        scenes = normalize_hash_array(intel["scenes"], meta["scenes"]).first(20)
        people = Array(intel["people"] || meta["face_people"]).first(10)
        face_count = (intel["face_count"] || meta["face_count"]).to_i
        next if objects.empty? && hashtags.empty? && mentions.empty? && profile_handles.empty? && topics.empty? && scenes.empty? && ocr_text.blank? && transcript.blank? && face_count <= 0

        {
          event_id: event.id,
          occurred_at: event.occurred_at&.iso8601 || event.detected_at&.iso8601,
          topics: topics,
          objects: objects,
          scenes: scenes,
          hashtags: hashtags,
          mentions: mentions,
          profile_handles: profile_handles,
          ocr_text: ocr_text.to_s.byteslice(0, 220),
          transcript: transcript.to_s.byteslice(0, 220),
          face_count: face_count,
          scenes_count: scenes.length,
          people: people
        }
      end.compact
  rescue StandardError
    []
  end

  def format_story_intelligence_context(rows)
    entries = Array(rows).first(10)
    return "" if entries.empty?

    lines = entries.map do |row|
      parts = []
      parts << "topics=#{Array(row[:topics]).join(',')}" if Array(row[:topics]).any?
      parts << "objects=#{Array(row[:objects]).join(',')}" if Array(row[:objects]).any?
      parts << "hashtags=#{Array(row[:hashtags]).join(',')}" if Array(row[:hashtags]).any?
      parts << "mentions=#{Array(row[:mentions]).join(',')}" if Array(row[:mentions]).any?
      parts << "handles=#{Array(row[:profile_handles]).join(',')}" if Array(row[:profile_handles]).any?
      parts << "faces=#{row[:face_count].to_i}" if row[:face_count].to_i.positive?
      parts << "scenes=#{row[:scenes_count].to_i}" if row[:scenes_count].to_i.positive?
      parts << "ocr=#{row[:ocr_text]}" if row[:ocr_text].to_s.present?
      parts << "transcript=#{row[:transcript]}" if row[:transcript].to_s.present?
      "- #{parts.join(' | ')}"
    end

    "Recent structured story intelligence:\n#{lines.join("\n")}"
  end

  def build_compact_historical_context(profile:, historical_story_context:, verified_profile_history:, profile_preparation:)
    summary = []
    if profile
      summary << profile.history_narrative_text(max_chunks: 2).to_s
    end
    structured = format_story_intelligence_context(historical_story_context)
    summary << structured.to_s
    summary << format_verified_profile_history(verified_profile_history)
    summary << format_profile_preparation(profile_preparation)

    compact = summary
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .join("\n")

    compact.byteslice(0, 650)
  end

  def latest_profile_comment_preparation(profile)
    meta = profile&.instagram_profile_behavior_profile&.metadata
    payload = meta.is_a?(Hash) ? meta["comment_generation_preparation"] : nil
    payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
  rescue StandardError
    {}
  end

  def recent_analyzed_profile_history(profile)
    return [] unless profile

    profile.instagram_profile_posts
      .recent_first
      .limit(12)
      .map do |post|
        analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
        faces = post.instagram_post_faces
        next if analysis.blank? && !faces.exists?

        {
          post_id: post.id,
          shortcode: post.shortcode,
          taken_at: post.taken_at&.iso8601,
          caption: post.caption.to_s.byteslice(0, 220),
          image_description: analysis["image_description"].to_s.byteslice(0, 220),
          topics: Array(analysis["topics"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          objects: Array(analysis["objects"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          hashtags: Array(analysis["hashtags"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          mentions: Array(analysis["mentions"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          face_count: faces.count,
          primary_face_count: faces.where(role: "primary_user").count,
          secondary_face_count: faces.where(role: "secondary_person").count
        }
      end.compact
  rescue StandardError
    []
  end

  def build_conversational_voice_profile(profile:, historical_story_context:, verified_profile_history:, profile_preparation:)
    behavior_summary = profile&.instagram_profile_behavior_profile&.behavioral_summary
    behavior_summary = {} unless behavior_summary.is_a?(Hash)
    preparation = profile_preparation.is_a?(Hash) ? profile_preparation : {}
    recent_comments = recent_llm_comments_for_profile(profile).first(6)
    recent_topics = Array(verified_profile_history).flat_map { |row| Array(row[:topics]) }.map(&:to_s).reject(&:blank?).uniq.first(10)
    recurring_story_topics = Array(historical_story_context).flat_map { |row| Array(row[:topics]) }.map(&:to_s).reject(&:blank?).uniq.first(10)

    {
      author_type: determine_author_type(profile),
      profile_tags: profile ? profile.profile_tags.pluck(:name).sort.first(10) : [],
      bio_keywords: extract_topics_from_profile(profile).first(10),
      recurring_topics: (recent_topics + recurring_story_topics + Array(behavior_summary["topic_clusters"]).map(&:first)).map(&:to_s).reject(&:blank?).uniq.first(12),
      recurring_hashtags: Array(behavior_summary["top_hashtags"]).map(&:first).map(&:to_s).reject(&:blank?).first(10),
      frequent_people_labels: Array(behavior_summary["frequent_secondary_persons"]).map { |row| row.is_a?(Hash) ? row["label"] || row[:label] : nil }.map(&:to_s).reject(&:blank?).uniq.first(8),
      prior_comment_examples: recent_comments.map { |value| value.to_s.byteslice(0, 120) },
      identity_consistency: preparation[:identity_consistency].is_a?(Hash) ? preparation[:identity_consistency] : preparation["identity_consistency"],
      profile_preparation_reason: preparation[:reason].to_s.presence || preparation["reason"].to_s.presence
    }.compact
  rescue StandardError
    {}
  end

  def format_verified_profile_history(rows)
    entries = Array(rows).first(8)
    return "" if entries.empty?

    lines = entries.map do |row|
      parts = []
      parts << "shortcode=#{row[:shortcode]}" if row[:shortcode].to_s.present?
      parts << "topics=#{Array(row[:topics]).join(',')}" if Array(row[:topics]).any?
      parts << "objects=#{Array(row[:objects]).join(',')}" if Array(row[:objects]).any?
      parts << "hashtags=#{Array(row[:hashtags]).join(',')}" if Array(row[:hashtags]).any?
      parts << "mentions=#{Array(row[:mentions]).join(',')}" if Array(row[:mentions]).any?
      parts << "faces=#{row[:face_count].to_i}" if row[:face_count].to_i.positive?
      parts << "primary_faces=#{row[:primary_face_count].to_i}" if row[:primary_face_count].to_i.positive?
      parts << "secondary_faces=#{row[:secondary_face_count].to_i}" if row[:secondary_face_count].to_i.positive?
      parts << "desc=#{row[:image_description]}" if row[:image_description].to_s.present?
      "- #{parts.join(' | ')}"
    end

    "Recent analyzed profile posts:\n#{lines.join("\n")}"
  end

  def format_profile_preparation(payload)
    data = payload.is_a?(Hash) ? payload : {}
    return "" if data.blank?

    identity = data[:identity_consistency].is_a?(Hash) ? data[:identity_consistency] : data["identity_consistency"]
    analysis = data[:analysis].is_a?(Hash) ? data[:analysis] : data["analysis"]

    parts = []
    parts << "ready=#{ActiveModel::Type::Boolean.new.cast(data[:ready_for_comment_generation] || data["ready_for_comment_generation"])}"
    parts << "reason=#{data[:reason_code] || data["reason_code"]}"
    parts << "analyzed_posts=#{analysis[:analyzed_posts_count] || analysis["analyzed_posts_count"]}" if analysis.is_a?(Hash)
    parts << "structured_posts=#{analysis[:posts_with_structured_signals_count] || analysis["posts_with_structured_signals_count"]}" if analysis.is_a?(Hash)
    if identity.is_a?(Hash)
      parts << "identity_consistent=#{ActiveModel::Type::Boolean.new.cast(identity[:consistent] || identity["consistent"])}"
      parts << "identity_ratio=#{identity[:dominance_ratio] || identity["dominance_ratio"]}"
      parts << "identity_reason=#{identity[:reason_code] || identity["reason_code"]}"
    end
    return "" if parts.empty?

    "Profile preparation: #{parts.join(' | ')}"
  end

  def story_timeline_data
    raw = metadata.is_a?(Hash) ? metadata : {}
    story = instagram_stories.order(taken_at: :desc, id: :desc).first
    posted_at = raw["upload_time"].presence || raw["taken_at"].presence || story&.taken_at&.iso8601
    downloaded_at = raw["downloaded_at"].presence || occurred_at&.iso8601 || created_at&.iso8601

    {
      story_posted_at: posted_at,
      downloaded_to_system_at: downloaded_at,
      event_detected_at: detected_at&.iso8601
    }
  end

  def estimated_generation_seconds(queue_state:)
    base = 18
    queue_size =
      begin
        require "sidekiq/api"
        Sidekiq::Queue.new("ai").size.to_i
      rescue StandardError
        0
      end
    queue_factor = queue_state ? queue_size * 4 : [queue_size - 1, 0].max * 3
    attempt_factor = llm_comment_attempts.to_i * 6
    preprocess_factor = local_context_preprocess_penalty
    (base + queue_factor + attempt_factor + preprocess_factor).clamp(10, 240)
  end

  def local_context_preprocess_penalty
    raw = metadata.is_a?(Hash) ? metadata : {}
    has_context = raw["local_story_intelligence"].is_a?(Hash) ||
      raw["ocr_text"].to_s.present? ||
      Array(raw["content_signals"]).any?
    return 0 if has_context

    media_type = media&.blob&.content_type.to_s.presence || raw["media_content_type"].to_s
    media_type.start_with?("image/") ? 16 : 8
  rescue StandardError
    0
  end

  def recent_llm_comments_for_profile(profile)
    return [] unless profile

    profile.instagram_profile_events
      .where.not(id: id)
      .where.not(llm_generated_comment: [nil, ""])
      .order(llm_comment_generated_at: :desc, id: :desc)
      .limit(12)
      .pluck(:llm_generated_comment)
      .map(&:to_s)
      .reject(&:blank?)
  rescue StandardError
    []
  end

  def build_cv_ocr_evidence(local_story_intelligence:)
    payload = local_story_intelligence.is_a?(Hash) ? local_story_intelligence : {}
    {
      source: payload[:source].to_s,
      reason: payload[:reason].to_s.presence,
      ocr_text: payload[:ocr_text].to_s,
      transcript: payload[:transcript].to_s,
      objects: Array(payload[:objects]).first(20),
      scenes: Array(payload[:scenes]).first(20),
      hashtags: Array(payload[:hashtags]).first(20),
      mentions: Array(payload[:mentions]).first(20),
      profile_handles: Array(payload[:profile_handles]).first(20),
      source_account_reference: payload[:source_account_reference].to_s,
      source_profile_ids: Array(payload[:source_profile_ids]).first(10),
      media_type: payload[:media_type].to_s,
      face_count: payload[:face_count].to_i,
      people: Array(payload[:people]).first(10),
      object_detections: normalize_hash_array(payload[:object_detections]).first(30),
      ocr_blocks: normalize_hash_array(payload[:ocr_blocks]).first(30)
    }
  end

  def build_historical_comparison(current:, historical_story_context:)
    current_hash = current.is_a?(Hash) ? current : {}
    current_topics = Array(current_hash[:topics]).map(&:to_s).reject(&:blank?).uniq
    current_objects = Array(current_hash[:objects]).map(&:to_s).reject(&:blank?).uniq
    current_scenes = Array(current_hash[:scenes]).map { |row| row.is_a?(Hash) ? row[:type] || row["type"] : row }.map(&:to_s).reject(&:blank?).uniq
    current_hashtags = Array(current_hash[:hashtags]).map(&:to_s).reject(&:blank?).uniq
    current_mentions = Array(current_hash[:mentions]).map(&:to_s).reject(&:blank?).uniq
    current_profile_handles = Array(current_hash[:profile_handles]).map(&:to_s).reject(&:blank?).uniq
    current_people = Array(current_hash[:people]).map { |row| row.is_a?(Hash) ? row[:person_id] || row["person_id"] : nil }.compact.map(&:to_s)

    historical_rows = Array(historical_story_context)
    hist_topics = historical_rows.flat_map { |row| Array(row[:topics] || row["topics"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_objects = historical_rows.flat_map { |row| Array(row[:objects] || row["objects"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_scenes = historical_rows.flat_map { |row| Array(row[:scenes] || row["scenes"]) }
      .map { |row| row.is_a?(Hash) ? row[:type] || row["type"] : row }
      .map(&:to_s)
      .reject(&:blank?)
      .uniq
    hist_hashtags = historical_rows.flat_map { |row| Array(row[:hashtags] || row["hashtags"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_mentions = historical_rows.flat_map { |row| Array(row[:mentions] || row["mentions"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_profile_handles = historical_rows.flat_map { |row| Array(row[:profile_handles] || row["profile_handles"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_people = historical_rows.flat_map { |row| Array(row[:people] || row["people"]) }
      .map { |row| row.is_a?(Hash) ? row[:person_id] || row["person_id"] : nil }
      .compact
      .map(&:to_s)
      .uniq

    {
      shared_topics: (current_topics & hist_topics).first(12),
      novel_topics: (current_topics - hist_topics).first(12),
      shared_objects: (current_objects & hist_objects).first(12),
      novel_objects: (current_objects - hist_objects).first(12),
      shared_scenes: (current_scenes & hist_scenes).first(12),
      novel_scenes: (current_scenes - hist_scenes).first(12),
      recurring_hashtags: (current_hashtags & hist_hashtags).first(12),
      recurring_mentions: (current_mentions & hist_mentions).first(12),
      recurring_profile_handles: (current_profile_handles & hist_profile_handles).first(12),
      recurring_people_ids: (current_people & hist_people).first(12),
      has_historical_overlap: ((current_topics & hist_topics).any? || (current_objects & hist_objects).any? || (current_scenes & hist_scenes).any? || (current_hashtags & hist_hashtags).any? || (current_profile_handles & hist_profile_handles).any?)
    }
  end

  def normalize_hash_array(*values)
    values.flat_map { |value| Array(value) }.select { |row| row.is_a?(Hash) }
  end

  def normalize_people_rows(*values)
    rows = values.flat_map { |value| Array(value) }

    rows.filter_map do |row|
      next unless row.is_a?(Hash)

      {
        person_id: row[:person_id] || row["person_id"],
        role: (row[:role] || row["role"]).to_s.presence,
        label: (row[:label] || row["label"]).to_s.presence,
        similarity: (row[:similarity] || row["similarity"] || row[:match_similarity] || row["match_similarity"]).to_f,
        relationship: (row[:relationship] || row["relationship"]).to_s.presence,
        appearances: (row[:appearances] || row["appearances"]).to_i,
        linked_usernames: Array(row[:linked_usernames] || row["linked_usernames"]).map(&:to_s).reject(&:blank?).first(8),
        age: (row[:age] || row["age"]).to_f.positive? ? (row[:age] || row["age"]).to_f.round(1) : nil,
        age_range: (row[:age_range] || row["age_range"]).to_s.presence,
        gender: (row[:gender] || row["gender"]).to_s.presence,
        gender_score: (row[:gender_score] || row["gender_score"]).to_f
      }.compact
    end.uniq { |row| [ row[:person_id], row[:role], row[:similarity].to_f.round(3), row[:label] ] }
  end

  def normalize_object_detections(*values, limit: 120)
    rows = normalize_hash_array(*values).map do |row|
      label = (row[:label] || row["label"] || row[:description] || row["description"]).to_s.downcase.strip
      next if label.blank?

      {
        label: label,
        confidence: (row[:confidence] || row["confidence"] || row[:score] || row["score"] || row[:max_confidence] || row["max_confidence"]).to_f,
        bbox: row[:bbox].is_a?(Hash) ? row[:bbox] : (row["bbox"].is_a?(Hash) ? row["bbox"] : {}),
        timestamps: Array(row[:timestamps] || row["timestamps"]).map(&:to_f).first(80)
      }
    end.compact

    rows
      .uniq { |row| [ row[:label], row[:bbox], row[:timestamps].first(6) ] }
      .sort_by { |row| -row[:confidence].to_f }
      .first(limit.to_i.clamp(1, 300))
  end

  def story_excluded_from_narrative?(ownership:, policy:)
    ownership_hash = ownership.is_a?(Hash) ? ownership : {}
    policy_hash = policy.is_a?(Hash) ? policy : {}
    label = (ownership_hash[:label] || ownership_hash["label"]).to_s
    return true if %w[reshare third_party_content unrelated_post meme_reshare].include?(label)

    allow_comment_value = if policy_hash.key?(:allow_comment)
      policy_hash[:allow_comment]
    else
      policy_hash["allow_comment"]
    end
    allow_comment = ActiveModel::Type::Boolean.new.cast(allow_comment_value)
    reason_code = (policy_hash[:reason_code] || policy_hash["reason_code"]).to_s
    !allow_comment && reason_code.match?(/(reshare|third_party|unrelated|meme)/)
  end

  def extract_source_account_reference(raw:, story_meta:)
    value = raw["story_ref"].to_s.presence || story_meta["story_ref"].to_s.presence
    value = value.delete_suffix(":") if value.to_s.present?
    return value if value.to_s.present?

    url = raw["story_url"].to_s.presence || raw["permalink"].to_s.presence || story_meta["story_url"].to_s.presence
    return nil if url.blank?

    match = url.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i) || url.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i)
    match ? match[1].to_s.downcase : nil
  end

  def extract_source_profile_ids_from_metadata(raw:, story_meta:)
    rows = []
    %w[source_profile_id owner_id profile_id user_id source_user_id].each do |key|
      value = raw[key] || story_meta[key]
      rows << value.to_s if value.to_s.match?(/\A\d+\z/)
    end
    story_id = raw["story_id"].to_s.presence || story_meta["story_id"].to_s
    story_id.to_s.scan(/(?<!\w)\d{5,}(?!\w)/).each { |token| rows << token }
    rows.uniq.first(10)
  end

  def determine_author_type(profile)
    return "unknown" unless profile

    bio = profile.bio.to_s.downcase

    if bio.include?("creator") || bio.include?("artist")
      "creator"
    elsif bio.include?("business") || bio.include?("entrepreneur")
      "business"
    else
      "personal"
    end
  end

  def extract_topics_from_profile(profile)
    return [] unless profile&.bio

    topics = []
    bio = profile.bio.downcase

    topic_keywords = {
      "fitness" => %w[fitness gym workout health],
      "food" => %w[food cooking chef recipe],
      "travel" => %w[travel wanderlust adventure],
      "fashion" => %w[fashion style outfit beauty],
      "tech" => %w[tech technology coding software],
      "art" => %w[art artist creative design],
      "business" => %w[business entrepreneur startup],
      "photography" => %w[photography photo camera]
    }

    topic_keywords.each do |topic, keywords|
      topics << topic if keywords.any? { |keyword| bio.include?(keyword) }
    end

    topics.uniq
  end
end
