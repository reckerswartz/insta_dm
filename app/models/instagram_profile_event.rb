class InstagramProfileEvent < ApplicationRecord
  belongs_to :instagram_profile

  has_one_attached :media
  has_many :instagram_stories, foreign_key: :source_event_id, dependent: :nullify

  validates :kind, presence: true
  validates :external_id, presence: true
  validates :detected_at, presence: true

  after_commit :broadcast_account_audit_logs_refresh
  after_commit :broadcast_story_archive_refresh, on: %i[create update]
  after_commit :append_profile_history_narrative, on: :create

  # LLM Comment validations
  validates :llm_comment_provider, inclusion: { in: %w[ollama local], allow_nil: true }
  validate :llm_comment_consistency, on: :update

  STORY_ARCHIVE_EVENT_KINDS = %w[
    story_downloaded
    story_image_downloaded_via_feed
    story_media_downloaded_via_feed
  ].freeze

  # LLM Comment methods
  def has_llm_generated_comment?
    llm_generated_comment.present?
  end

  def generate_llm_comment!(provider: :ollama, model: nil)
    return if has_llm_generated_comment?

    # Broadcast generation start
    broadcast_llm_comment_generation_start

    # Build comprehensive context for comment generation
    context = build_comment_context
    technical_details = capture_technical_details(context)
    
    # Use existing local engagement comment generator
    generator = Ai::LocalEngagementCommentGenerator.new(
      ollama_client: Ai::OllamaClient.new,
      model: model
    )

    result = generator.generate!(**context)
    
    # Enhance result with technical details
    enhanced_result = result.merge(technical_details)
    
    if result[:status] == "ok"
      update!(
        llm_generated_comment: result[:comment_suggestions]&.first,
        llm_comment_generated_at: Time.current,
        llm_comment_model: result[:model],
        llm_comment_provider: provider.to_s,
        llm_comment_metadata: enhanced_result.slice(:prompt, :source, :fallback_used, :confidence_score, :technical_details)
      )
      
      # Broadcast refresh to update UI
      broadcast_story_archive_refresh
      
      # Broadcast LLM comment generation update via ActionCable
      broadcast_llm_comment_generation_update(enhanced_result)
      
      enhanced_result
    else
      # Broadcast generation error
      broadcast_llm_comment_generation_error(result[:error_message])
      raise "Failed to generate LLM comment: #{result[:error_message]}"
    end
  end

  def reply_comment
    metadata["reply_comment"] if metadata.is_a?(Hash)
  end

  def story_archive_item?
    STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)
  end

  def capture_technical_details(context)
    profile = instagram_profile
    media_blob = media.blob
    
    {
      timestamp: Time.current.iso8601,
      event_id: id,
      story_id: metadata["story_id"],
      media_info: media_blob ? {
        content_type: media_blob&.content_type,
        size_bytes: media_blob&.byte_size,
        dimensions: metadata.slice("media_width", "media_height"),
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
        rules_applied: context[:post_payload]&.dig(:rules)
      }
    }
  end

  def broadcast_llm_comment_generation_update(generation_result)
    account = instagram_profile&.instagram_account
    return unless account

    ActionCable.server.broadcast(
      "llm_comment_generation_#{account.id}",
      {
        event_id: id,
        status: 'completed',
        comment: llm_generated_comment,
        generated_at: llm_comment_generated_at,
        model: llm_comment_model,
        provider: llm_comment_provider,
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
        status: 'started',
        message: 'Generating comment...'
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
        status: 'error',
        error: error_message,
        message: 'Failed to generate comment'
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

  def llm_comment_consistency
    if llm_generated_comment.present? && llm_comment_generated_at.blank?
      errors.add(:llm_comment_generated_at, "must be present when LLM comment is set")
    end
    
    if llm_generated_comment.present? && llm_comment_provider.blank?
      errors.add(:llm_comment_provider, "must be present when LLM comment is set")
    end
    
    if llm_generated_comment.blank? && (llm_comment_generated_at.present? || llm_comment_provider.present?)
      errors.add(:llm_generated_comment, "must be present when comment metadata is set")
    end
  end

  def build_comment_context
    # Extract relevant context for comment generation
    profile = instagram_profile
    media_blob = media.blob
    
    post_payload = {
      post: {
        id: id,
        caption: nil, # Stories don't have captions
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

    # Get image description if available from AI analysis
    image_description = nil
    if media_blob && media_blob.content_type&.start_with?("image/")
      # Look for existing AI analysis
      ai_analysis = AiAnalysis.where(
        analyzable_type: "InstagramProfileEvent",
        analyzable_id: id,
        purpose: "image_description"
      ).first
      
      image_description = ai_analysis&.response_text if ai_analysis
    end

    {
      post_payload: post_payload,
      image_description: image_description || "Story media",
      topics: extract_topics_from_profile(profile),
      author_type: determine_author_type(profile)
    }
  end

  def determine_author_type(profile)
    return "unknown" unless profile
    
    if profile.bio&.include?("creator") || profile.bio&.include?("artist")
      "creator"
    elsif profile.bio&.include?("business") || profile.bio&.include?("entrepreneur")
      "business"
    else
      "personal"
    end
  end

  def extract_topics_from_profile(profile)
    return [] unless profile&.bio
    
    # Simple topic extraction from bio
    topics = []
    bio = profile.bio.downcase
    
    # Common topics to look for
    topic_keywords = {
      'fitness' => ['fitness', 'gym', 'workout', 'health'],
      'food' => ['food', 'cooking', 'chef', 'recipe'],
      'travel' => ['travel', 'wanderlust', 'adventure'],
      'fashion' => ['fashion', 'style', 'outfit', 'beauty'],
      'tech' => ['tech', 'technology', 'coding', 'software'],
      'art' => ['art', 'artist', 'creative', 'design'],
      'business' => ['business', 'entrepreneur', 'startup'],
      'photography' => ['photography', 'photo', 'camera']
    }
    
    topic_keywords.each do |topic, keywords|
      topics << topic if keywords.any? { |keyword| bio.include?(keyword) }
    end
    
    topics.uniq
  end
end
