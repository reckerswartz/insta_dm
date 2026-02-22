# frozen_string_literal: true

# Utility module for data normalization operations
# Extracted from multiple classes to follow DRY principle
module DataNormalizationHelper
  extend ActiveSupport::Concern

  # Normalizes hash arrays by filtering and ensuring hash structure
  def normalize_hash_array(*values)
    values.flat_map { |value| Array(value) }.select { |row| row.is_a?(Hash) }
  end

  # Normalizes object detection data with confidence scores and bounding boxes
  def normalize_object_detections(*values, limit: 120)
    rows = normalize_hash_array(*values).map do |row|
      label = extract_detection_label(row)
      next if label.blank?

      {
        label: label,
        confidence: extract_detection_confidence(row),
        bbox: extract_detection_bbox(row),
        timestamps: extract_detection_timestamps(row)
      }
    end.compact

    rows
      .uniq { |row| [row[:label], row[:bbox], row[:timestamps].first(6)] }
      .sort_by { |row| -row[:confidence].to_f }
      .first(limit.to_i.clamp(1, 300))
  end

  # Normalizes people/face detection rows with consistent structure
  def normalize_people_rows(*values)
    rows = values.flat_map { |value| Array(value) }

    rows.filter_map do |row|
      next unless row.is_a?(Hash)

      {
        person_id: extract_person_id(row),
        role: extract_role(row),
        label: extract_label(row),
        similarity: extract_similarity(row),
        relationship: extract_relationship(row),
        appearances: extract_appearances(row),
        linked_usernames: extract_linked_usernames(row),
        age: extract_age(row),
        age_range: extract_age_range(row),
        gender: extract_gender(row),
        gender_score: extract_gender_score(row)
      }.compact
    end.uniq { |row| [row[:person_id], row[:role], row[:similarity].to_f.round(3), row[:label]] }
  end

  # Merges unique values from multiple arrays, deduplicating and limiting
  def merge_unique_values(*values, limit: 40)
    values.flat_map { |value| Array(value) }
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .first(limit)
  end

  # Returns the first non-blank value from the given values
  def first_present(*values)
    values.each do |value|
      text = value.to_s.strip
      return text if text.present?
    end
    nil
  end

  # Normalizes and extracts hashtags from text
  def extract_hashtags_from_text(text)
    return [] if text.to_s.blank?
    
    text.to_s.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq
  end

  # Normalizes and extracts mentions from text
  def extract_mentions_from_text(text)
    return [] if text.to_s.blank?
    
    text.to_s.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq
  end

  # Normalizes and extracts profile handles from text
  def extract_profile_handles_from_text(text)
    return [] if text.to_s.blank?
    
    text.to_s.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
      .map(&:downcase)
      .select { |token| token.include?("_") || token.include?(".") }
      .reject { |token| token.include?("instagram.com") }
      .uniq
  end

  # Extracts source account reference from metadata
  def extract_source_account_reference(raw:, story_meta:)
    value = raw["story_ref"].to_s.presence || story_meta["story_ref"].to_s.presence
    value = value.delete_suffix(":") if value.to_s.present?
    return value if value.to_s.present?

    url = raw["story_url"].to_s.presence || raw["permalink"].to_s.presence || story_meta["story_url"].to_s.presence
    return nil if url.blank?

    extract_username_from_url(url)
  end

  # Extracts source profile IDs from metadata
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

  private

  def extract_detection_label(row)
    (row[:label] || row["label"] || row[:description] || row["description"]).to_s.downcase.strip
  end

  def extract_detection_confidence(row)
    (row[:confidence] || row["confidence"] || row[:score] || row["score"] || row[:max_confidence] || row["max_confidence"]).to_f
  end

  def extract_detection_bbox(row)
    row[:bbox].is_a?(Hash) ? row[:bbox] : (row["bbox"].is_a?(Hash) ? row["bbox"] : {})
  end

  def extract_detection_timestamps(row)
    Array(row[:timestamps] || row["timestamps"]).map(&:to_f).first(80)
  end

  def extract_person_id(row)
    row[:person_id] || row["person_id"]
  end

  def extract_role(row)
    (row[:role] || row["role"]).to_s.presence
  end

  def extract_label(row)
    (row[:label] || row["label"]).to_s.presence
  end

  def extract_similarity(row)
    (row[:similarity] || row["similarity"] || row[:match_similarity] || row["match_similarity"]).to_f
  end

  def extract_relationship(row)
    (row[:relationship] || row["relationship"]).to_s.presence
  end

  def extract_appearances(row)
    (row[:appearances] || row["appearances"]).to_i
  end

  def extract_linked_usernames(row)
    Array(row[:linked_usernames] || row["linked_usernames"]).map(&:to_s).reject(&:blank?).first(8)
  end

  def extract_age(row)
    age = (row[:age] || row["age"]).to_f
    age.positive? ? age.round(1) : nil
  end

  def extract_age_range(row)
    (row[:age_range] || row["age_range"]).to_s.presence
  end

  def extract_gender(row)
    (row[:gender] || row["gender"]).to_s.presence
  end

  def extract_gender_score(row)
    (row[:gender_score] || row["gender_score"]).to_f
  end

  def extract_username_from_url(url)
    match = url.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i) || 
            url.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i)
    match ? match[1].to_s.downcase : nil
  end
end
