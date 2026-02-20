require 'active_support/concern'

module InstagramProfileEvent::LocalStoryIntelligence
  extend ActiveSupport::Concern

  included do
    class LocalStoryIntelligenceUnavailableError < StandardError
      attr_reader :reason, :source

      def initialize(message = nil, reason: nil, source: nil)
        @reason = reason.to_s.presence
        @source = source.to_s.presence
        super(message || "Local story intelligence unavailable")
      end
    end

    def local_story_intelligence_payload
      StoryIntelligence::PayloadBuilder.new(event: self).build_payload
    end

    def persist_local_story_intelligence!(payload)
      StoryIntelligence::PersistenceService.new(event: self).persist_local_intelligence!(payload)
    end

    def persist_validated_story_insights!(payload)
      StoryIntelligence::PersistenceService.new(event: self).persist_validated_insights!(payload)
    end

    def build_story_image_description(local_story_intelligence:)
      StoryIntelligence::PersistenceService.new(event: self).send(:build_story_image_description, local_story_intelligence)
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
  end

  private

  def local_story_intelligence_blank?(payload)
    return true unless payload.is_a?(Hash)
    
    # Check if there's any meaningful content
    has_face_context = payload[:face_count].to_i > 0
    has_scene_context = Array(payload[:scenes]).any?
    has_objects = Array(payload[:objects]).any?
    has_ocr_content = payload[:ocr_text].present? || Array(payload[:ocr_blocks]).any?
    has_transcript = payload[:transcript].present?
    has_hashtags = Array(payload[:hashtags]).any?
    has_mentions = Array(payload[:mentions]).any?
    has_topics = Array(payload[:topics]).any?
    has_people = Array(payload[:people]).any?
    
    # If any content exists, it's not blank
    !(has_face_context || has_scene_context || has_objects || has_ocr_content || 
      has_transcript || has_hashtags || has_mentions || has_topics || has_people)
  end
end
