class ProfileReevaluationService
  attr_reader :account, :profile

  def initialize(account:, profile:)
    @account = account
    @profile = profile
  end

  # Main entry point called after post/story analysis completes
  def reevaluate_after_content_scan!(content_type:, content_id:)
    Rails.logger.info("[ProfileReevaluationService] Starting re-evaluation for #{profile.username} after #{content_type} #{content_id}")
    
    # Check if re-evaluation should run
    return unless should_reevaluate?
    
    # Collect latest evidence from recent scans
    evidence = collect_demographic_evidence
    
    # Re-evaluate and update profile attributes
    update_profile_demographics!(evidence)
    
    # Handle uncertainty and schedule re-verification if needed
    handle_uncertainty_and_schedules!(evidence)
    
    # Record the re-evaluation event
    profile.record_event!(
      kind: "profile_reevaluated",
      external_id: "profile_reevaluated:#{content_type}:#{content_id}:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        trigger_content_type: content_type,
        trigger_content_id: content_id,
        evidence_sources: evidence[:sources],
        updates_made: evidence[:updates_made],
        confidence_improvements: evidence[:confidence_improvements],
        uncertainty_flags: evidence[:uncertainty_flags]
      }
    )
    
    Rails.logger.info("[ProfileReevaluationService] Completed re-evaluation for #{profile.username}")
  rescue StandardError => e
    Rails.logger.error("[ProfileReevaluationService] Failed for #{profile.username}: #{e.message}")
    raise
  end

  private

  def should_reevaluate?
    # Don't re-evaluate too frequently - minimum 30 minutes between updates
    return false if profile.ai_last_analyzed_at.present? && profile.ai_last_analyzed_at > 30.minutes.ago
    
    # Only re-evaluate if we have some existing data that could be improved
    has_existing_demographics = [
      profile.ai_estimated_age,
      profile.ai_estimated_gender,
      profile.ai_estimated_location
    ].any?
    
    # Or if we have recent content that could provide new evidence
    has_recent_content = recent_profile_posts.any? || recent_story_events.any?
    
    has_existing_demographics || has_recent_content
  end

  def collect_demographic_evidence
    evidence = {
      age: { values: [], confidences: [], sources: [] },
      gender: { values: [], confidences: [], sources: [] },
      location: { values: [], confidences: [], sources: [] },
      sources: [],
      updates_made: [],
      confidence_improvements: [],
      uncertainty_flags: []
    }

    # Collect from recent profile posts
    collect_from_profile_posts(evidence)
    
    # Collect from recent story events  
    collect_from_story_events(evidence)
    
    # Collect from recent profile analyses
    collect_from_profile_analyses(evidence)
    
    evidence
  end

  def collect_from_profile_posts(evidence)
    recent_profile_posts.limit(10).each do |post|
      next unless post.analysis.is_a?(Hash)
      
      inferred = post.analysis["inferred_demographics"]
      next unless inferred.is_a?(Hash)
      
      extract_demographic_from_source(evidence, inferred, "profile_post:#{post.shortcode}")
    end
  end

  def collect_from_story_events(evidence)
    recent_story_events.limit(15).each do |event|
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      intel = metadata["local_story_intelligence"].is_a?(Hash) ? metadata["local_story_intelligence"] : {}
      
      # Extract from OCR text and AI descriptions
      text_evidence = extract_demographics_from_text(
        metadata["ai_image_description"].to_s + " " + 
        intel["ocr_text"].to_s + " " + 
        Array(intel["hashtags"]).join(" ") + " " + 
        Array(intel["mentions"]).join(" ")
      )
      
      if text_evidence.any?
        extract_demographic_from_source(evidence, text_evidence, "story_event:#{event.id}")
      end
    end
  end

  def collect_from_profile_analyses(evidence)
    profile.ai_analyses
      .where(purpose: "profile", status: "succeeded")
      .recent_first
      .limit(5)
      .each do |analysis|
        analysis_data = analysis.analysis
        next unless analysis_data.is_a?(Hash)
        
        demo = analysis_data["demographic_estimates"] || analysis_data["self_declared"] || {}
        extract_demographic_from_source(evidence, demo, "profile_analysis:#{analysis.id}")
      end
  end

  def extract_demographic_from_source(evidence, demo, source)
    return unless demo.is_a?(Hash)
    
    evidence[:sources] << source
    
    # Age
    if demo["age"].present?
      age = demo["age"].to_i
      confidence = demo["age_confidence"] || demo["confidence"] || 0.3
      evidence[:age][:values] << age
      evidence[:age][:confidences] << confidence.to_f
      evidence[:age][:sources] << source
    end
    
    # Gender
    if demo["gender"].present?
      gender = normalize_gender(demo["gender"])
      confidence = demo["gender_confidence"] || demo["confidence"] || 0.3
      evidence[:gender][:values] << gender
      evidence[:gender][:confidences] << confidence.to_f
      evidence[:gender][:sources] << source
    end
    
    # Location
    if demo["location"].present?
      location = normalize_location(demo["location"])
      confidence = demo["location_confidence"] || demo["confidence"] || 0.25
      evidence[:location][:values] << location
      evidence[:location][:confidences] << confidence.to_f
      evidence[:location][:sources] << source
    end
  end

  def extract_demographics_from_text(text)
    text = text.downcase
    demographics = {}
    
    # Age extraction
    if (m = text.match(/\b([1-7]\d)\s?(?:yo|yrs?|years?\s*old)\b/))
      demographics[:age] = m[1].to_i
      demographics[:age_confidence] = 0.28
    end
    
    # Gender extraction
    if text.match?(/\b(she\/her)\b/)
      demographics[:gender] = "female"
      demographics[:gender_confidence] = 0.4
    elsif text.match?(/\b(he\/him)\b/)
      demographics[:gender] = "male"
      demographics[:gender_confidence] = 0.4
    elsif text.match?(/\b(they\/them|non[- ]?binary)\b/)
      demographics[:gender] = "non-binary"
      demographics[:gender_confidence] = 0.4
    end
    
    # Location extraction
    if (m = text.match(/(?:📍|based in|from)\s+([a-z][a-z\s,.-]{2,25})/))
      demographics[:location] = m[1].to_s.split(/[|•,]/).first.to_s.strip.titleize
      demographics[:location_confidence] = 0.35
    end
    
    demographics
  end

  def update_profile_demographics!(evidence)
    updates = {}
    
    # Update age if we have better evidence
    age_update = calculate_best_attribute_update(
      current_value: profile.ai_estimated_age,
      current_confidence: profile.ai_age_confidence,
      evidence_values: evidence[:age][:values],
      evidence_confidences: evidence[:age][:confidences]
    )
    
    if age_update
      updates[:ai_estimated_age] = age_update[:value]
      updates[:ai_age_confidence] = age_update[:confidence]
      evidence[:updates_made] << "age: #{age_update[:value]} (confidence: #{age_update[:confidence].round(2)})"
    end
    
    # Update gender if we have better evidence
    gender_update = calculate_best_attribute_update(
      current_value: normalize_gender(profile.ai_estimated_gender),
      current_confidence: profile.ai_gender_confidence,
      evidence_values: evidence[:gender][:values],
      evidence_confidences: evidence[:gender][:confidences]
    )
    
    if gender_update
      updates[:ai_estimated_gender] = gender_update[:value]
      updates[:ai_gender_confidence] = gender_update[:confidence]
      evidence[:updates_made] << "gender: #{gender_update[:value]} (confidence: #{gender_update[:confidence].round(2)})"
    end
    
    # Update location if we have better evidence
    location_update = calculate_best_attribute_update(
      current_value: normalize_location(profile.ai_estimated_location),
      current_confidence: profile.ai_location_confidence,
      evidence_values: evidence[:location][:values],
      evidence_confidences: evidence[:location][:confidences]
    )
    
    if location_update
      updates[:ai_estimated_location] = location_update[:value]
      updates[:ai_location_confidence] = location_update[:confidence]
      evidence[:updates_made] << "location: #{location_update[:value]} (confidence: #{location_update[:confidence].round(2)})"
    end
    
    # Apply updates if any
    if updates.any?
      updates[:ai_last_analyzed_at] = Time.current
      profile.update!(updates)
      
      # Update persona summary with re-evidence
      if evidence[:updates_made].any?
        summary_addition = "Re-evaluated after content scan: #{evidence[:updates_made].join(', ')}"
        new_summary = [profile.ai_persona_summary.to_s.presence, summary_addition].compact.join("\n")
        profile.update!(ai_persona_summary: new_summary)
      end
    end
  end

  def calculate_best_attribute_update(current_value:, current_confidence:, evidence_values:, evidence_confidences:)
    return nil if evidence_values.empty?
    
    # Find the most common value with highest average confidence
    value_groups = evidence_values.each_with_index.group_by(&:first)
    
    best_value = nil
    best_score = -1
    
    value_groups.each do |value, indices|
      confidences = indices.map { |_, i| evidence_confidences[i] || 0 }
      avg_confidence = confidences.sum / confidences.length
      frequency = indices.length.to_f / evidence_values.length
      
      # Score combines confidence and frequency
      score = avg_confidence * (1 + frequency)
      
      if score > best_score
        best_score = score
        best_value = value
      end
    end
    
    return nil unless best_value
    
    # Calculate combined confidence
    best_indices = value_groups[best_value].map(&:last)
    best_confidences = best_indices.map { |i| evidence_confidences[i] || 0 }
    combined_confidence = best_confidences.sum / best_confidences.length
    
    # Only update if we have better confidence or no current value
    current_confidence ||= 0
    
    if combined_confidence > current_confidence + 0.1 || current_value.blank?
      {
        value: best_value,
        confidence: combined_confidence
      }
    end
  end

  def normalize_gender(gender)
    return nil if gender.blank?
    
    case gender.to_s.downcase.strip
    when "female", "woman", "girl", "she", "her"
      "female"
    when "male", "man", "boy", "he", "him"
      "male"
    when "non-binary", "nonbinary", "they", "them"
      "non-binary"
    else
      gender.to_s.strip
    end
  end

  def normalize_location(location)
    return nil if location.blank?
    
    location.to_s.strip.titleize
  end

  def recent_profile_posts
    profile.instagram_profile_posts
      .where.not(analysis: nil)
      .where("analysis->>'inferred_demographics' IS NOT NULL")
      .recent_first
  end

  def recent_story_events
    profile.instagram_profile_events
      .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
      .where("metadata->>'ai_image_description' IS NOT NULL OR metadata->'local_story_intelligence'->>'ocr_text' IS NOT NULL")
      .recent_first
  end

  def handle_uncertainty_and_schedules!(evidence)
    # Check for low confidence attributes that need re-verification
    low_confidence_attributes = []
    
    if profile.ai_age_confidence.present? && profile.ai_age_confidence < 0.3
      low_confidence_attributes << "age"
    end
    
    if profile.ai_gender_confidence.present? && profile.ai_gender_confidence < 0.3
      low_confidence_attributes << "gender"
    end
    
    if profile.ai_location_confidence.present? && profile.ai_location_confidence < 0.25
      low_confidence_attributes << "location"
    end
    
    # Flag uncertainty for tracking
    if low_confidence_attributes.any?
      evidence[:uncertainty_flags] = low_confidence_attributes
      
      # Schedule re-verification if we have enough new content evidence
      if should_schedule_reverification?(evidence)
        schedule_profile_reverification!
      end
    end
    
    # Check for conflicting evidence
    check_for_conflicting_evidence(evidence)
  end

  def should_schedule_reverification?(evidence)
    # Only schedule if we have recent content that could provide better evidence
    recent_evidence_count = evidence[:sources].count { |source| 
      source.include?("profile_post:") || source.include?("story_event:")
    }
    
    # Need at least 3 recent content pieces to justify re-verification
    recent_evidence_count >= 3
  end

  def schedule_profile_reverification!
    # Schedule a full profile analysis to get better evidence
    AnalyzeInstagramProfileJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: nil
    )
    
    Rails.logger.info("[ProfileReevaluationService] Scheduled re-verification for #{profile.username} due to low confidence")
  end

  def check_for_conflicting_evidence(evidence)
    conflicts = []
    
    # Check for age conflicts
    if evidence[:age][:values].length > 1
      age_values = evidence[:age][:values].uniq
      if age_values.length > 1
        age_range = age_values.minmax
        if age_range[1] - age_range[0] > 10  # More than 10 years difference
          conflicts << "age_conflict: #{age_range.join('-')}"
        end
      end
    end
    
    # Check for gender conflicts
    if evidence[:gender][:values].length > 1
      gender_values = evidence[:gender][:values].uniq.map(&:downcase)
      if gender_values.length > 1 && !gender_values.include?("unknown")
        conflicts << "gender_conflict: #{gender_values.join('/')}"
      end
    end
    
    # Check for location conflicts
    if evidence[:location][:values].length > 1
      location_values = evidence[:location][:values].uniq
      if location_values.length > 1
        conflicts << "location_conflict: #{location_values.join('/')}"
      end
    end
    
    # Add conflicts to uncertainty flags
    if conflicts.any?
      evidence[:uncertainty_flags].concat(conflicts)
      Rails.logger.warn("[ProfileReevaluationService] Conflicting evidence for #{profile.username}: #{conflicts.join(', ')}")
    end
  end
end
