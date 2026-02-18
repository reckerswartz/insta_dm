class InstagramProfileEvent < ApplicationRecord
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

  LLM_SUCCESS_STATUSES = %w[ok fallback_used error_fallback].freeze

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

  def generate_llm_comment!(provider: :ollama, model: nil)
    if has_llm_generated_comment?
      update_column(:llm_comment_status, "completed") if llm_comment_status.to_s != "completed"

      return {
        status: "already_completed",
        selected_comment: llm_generated_comment,
        relevance_score: llm_comment_relevance_score
      }
    end

    context = build_comment_context
    technical_details = capture_technical_details(context)

    generator = Ai::LocalEngagementCommentGenerator.new(
      ollama_client: Ai::OllamaClient.new,
      model: model
    )

    result = generator.generate!(**context)
    enhanced_result = result.merge(technical_details: technical_details)

    unless LLM_SUCCESS_STATUSES.include?(result[:status].to_s)
      raise "Failed to generate LLM comment: #{result[:error_message]}"
    end

    ranked = Ai::CommentRelevanceScorer.rank(
      suggestions: result[:comment_suggestions],
      image_description: context[:image_description],
      topics: context[:topics],
      historical_comments: context[:historical_comments]
    )

    selected_comment, score = ranked.first
    raise "No valid comment suggestions generated" if selected_comment.to_s.blank?

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
        "ranked_candidates" => ranked.first(8).map { |text, value| { "comment" => text, "score" => value } },
        "selected_comment" => selected_comment,
        "selected_relevance_score" => score,
        "generated_at" => Time.current.iso8601
      )
    )

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

    {
      timestamp: Time.current.iso8601,
      event_id: id,
      story_id: metadata.is_a?(Hash) ? metadata["story_id"] : nil,
      media_info: media_blob ? {
        content_type: media_blob.content_type,
        size_bytes: media_blob.byte_size,
        dimensions: metadata.is_a?(Hash) ? metadata.slice("media_width", "media_height") : {},
        url: Rails.application.routes.url_helpers.rails_blob_path(media, only_path: true)
      } : {},
      profile_analysis: {
        username: profile&.username,
        display_name: profile&.display_name,
        bio: profile&.bio,
        bio_length: profile&.bio&.length || 0,
        detected_author_type: determine_author_type(profile),
        extracted_topics: extract_topics_from_profile(profile)
      },
      prompt_engineering: {
        final_prompt: context[:post_payload],
        image_description: context[:image_description],
        topics_used: context[:topics],
        author_classification: context[:author_type],
        historical_context: context[:historical_context],
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
        message: "Comment generation queued"
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
        message: "Generating comment..."
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

    post_payload = {
      post: {
        id: id,
        caption: nil,
        media_url: Rails.application.routes.url_helpers.rails_blob_path(media, only_path: true)
      },
      author_profile: {
        username: profile&.username,
        display_name: profile&.display_name,
        bio: profile&.bio
      },
      rules: {
        max_length: 140,
        tone: "friendly, engaging"
      }
    }

    image_description = nil
    if media.attached? && media.blob&.content_type&.start_with?("image/")
      ai_analysis = AiAnalysis.where(
        analyzable_type: "InstagramProfileEvent",
        analyzable_id: id,
        purpose: "image_description"
      ).first

      image_description = ai_analysis&.response_text
    end

    historical_comments = recent_llm_comments_for_profile(profile)

    {
      post_payload: post_payload,
      image_description: image_description || "Story media",
      topics: extract_topics_from_profile(profile),
      author_type: determine_author_type(profile),
      historical_comments: historical_comments,
      historical_context: profile&.history_narrative_text(max_chunks: 4)
    }
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
