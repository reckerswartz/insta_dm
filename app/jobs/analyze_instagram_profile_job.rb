class AnalyzeInstagramProfileJob < ApplicationJob
require "base64"
require "digest"

  queue_as :ai
  MAX_AI_IMAGE_COUNT = 5
  MAX_PROFILE_IMAGE_DESCRIPTION_COUNT = 5
  MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: "analyze_profile",
      profile_action_log_id: profile_action_log_id
    )
    action_log.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id })

    collected = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
      posts_limit: nil,
      comments_limit: 20
    )
    described_posts = enrich_first_profile_images!(account: account, profile: profile, collected_posts: collected[:posts])

    payload = build_profile_payload(profile: profile, collected_posts: collected[:posts], described_posts: described_posts)
    media = build_media_inputs(profile: profile, collected_posts: described_posts)

    run = Ai::Runner.new(account: account).analyze!(
      purpose: "profile",
      analyzable: profile,
      payload: payload,
      media: media
    )
    update_profile_demographics_from_analysis!(profile: profile, analysis: run.dig(:result, :analysis))
    aggregate_demographics_from_accumulated_json!(
      account: account,
      profile: profile,
      latest_profile_analysis: run.dig(:result, :analysis)
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "AI analysis completed for #{profile.username} via #{run[:provider].display_name}." }
    )
    action_log.mark_succeeded!(
      extra_metadata: { provider: run[:provider].key, provider_name: run[:provider].display_name },
      log_text: "AI analysis completed via #{run[:provider].display_name}"
    )
  rescue StandardError => e
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "AI analysis failed: #{e.message}" }
    ) if account
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })

    raise
  end

  private

  def find_or_create_action_log(account:, profile:, action:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: action,
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def build_profile_payload(profile:, collected_posts:, described_posts:)
    history_narrative = profile.history_narrative_text(max_chunks: 4)
    history_chunks = profile.history_narrative_chunks(max_chunks: 8)

    recent_messages =
      profile.instagram_messages
        .where(direction: "outgoing")
        .order(created_at: :desc)
        .limit(20)
        .pluck(:body, :created_at, :sent_at, :status)
        .map do |body, created_at, sent_at, status|
          {
            body: body,
            created_at: created_at&.iso8601,
            sent_at: sent_at&.iso8601,
            status: status
          }
        end

    recent_events =
      profile.instagram_profile_events
        .order(detected_at: :desc, id: :desc)
        .limit(100)
        .pluck(:kind, :external_id, :occurred_at, :detected_at)
        .map do |kind, external_id, occurred_at, detected_at|
          {
            kind: kind,
            external_id: external_id,
            occurred_at: occurred_at&.iso8601,
            detected_at: detected_at&.iso8601
          }
        end

    {
      username: profile.username,
      ig_user_id: profile.ig_user_id,
      display_name: profile.display_name,
      bio: profile.bio,
      following: profile.following,
      follows_you: profile.follows_you,
      can_message: profile.can_message,
      restriction_reason: profile.restriction_reason,
      last_active_at: profile.last_active_at&.iso8601,
      last_story_seen_at: profile.last_story_seen_at&.iso8601,
      last_post_at: profile.last_post_at&.iso8601,
      recent_outgoing_messages: recent_messages,
      recent_activity_events: recent_events,
      captured_profile_posts: Array(collected_posts).map do |post|
        {
          shortcode: post.shortcode,
          taken_at: post.taken_at&.iso8601,
          caption: post.caption,
          permalink: post.permalink_url,
          comments: post.instagram_profile_post_comments.recent_first.limit(10).map do |c|
            {
              author_username: c.author_username,
              body: c.body,
              commented_at: c.commented_at&.iso8601
            }
          end
        }
      end,
      captured_profile_image_descriptions: Array(described_posts).map do |post|
        analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
        {
          shortcode: post.shortcode,
          taken_at: post.taken_at&.iso8601,
          caption: post.caption,
          image_description: analysis["image_description"].to_s.presence,
          topics: Array(analysis["topics"]).first(10),
          comment_suggestions: Array(analysis["comment_suggestions"]).first(5)
        }
      end,
      historical_narrative_text: history_narrative,
      historical_narrative_chunks: history_chunks
    }
  end

  def build_media_inputs(profile:, collected_posts:)
    media = []

    if profile.avatar.attached?
      encoded = encode_blob_to_data_url(profile.avatar.blob)
      media << { type: "image", url: encoded, bytes: profile.avatar.blob.download } if encoded.present?
    elsif profile.profile_pic_url.to_s.strip.present?
      media << { type: "image", url: profile.profile_pic_url.to_s.strip }
    end

    Array(collected_posts).first(MAX_AI_IMAGE_COUNT).each do |post|
      next unless post.media.attached?
      blob = post.media.blob
      next unless blob&.content_type.to_s.start_with?("image/")
      next if blob.byte_size.to_i <= 0

      encoded = encode_blob_to_data_url(blob)
      next if encoded.blank?

      media << { type: "image", url: encoded, bytes: blob.download }
    end

    media
  end

  def enrich_first_profile_images!(account:, profile:, collected_posts:)
    selected = Array(collected_posts).select { |p| p.media.attached? }.first(MAX_PROFILE_IMAGE_DESCRIPTION_COUNT)

    selected.each do |post|
      analysis_data = run_post_image_description!(account: account, profile: profile, post: post)
      next unless analysis_data.is_a?(Hash)

      post.update!(
        ai_status: "analyzed",
        analyzed_at: Time.current,
        ai_provider: analysis_data["provider"],
        ai_model: analysis_data["model"],
        analysis: analysis_data["analysis"],
        metadata: (post.metadata || {}).merge(
          "analysis_input" => {
            "shortcode" => post.shortcode,
            "taken_at" => post.taken_at&.iso8601,
            "caption" => post.caption.to_s,
            "image_description" => analysis_data.dig("analysis", "image_description"),
            "topics" => Array(analysis_data.dig("analysis", "topics")).first(10),
            "comment_suggestions" => Array(analysis_data.dig("analysis", "comment_suggestions")).first(5)
          }
        )
      )
      Ai::ProfileAutoTagger.sync_from_post_analysis!(profile: profile, analysis: analysis_data["analysis"])
    rescue StandardError
      next
    end

    selected
  end

  def run_post_image_description!(account:, profile:, post:)
    history_narrative = profile.history_narrative_text(max_chunks: 3)
    history_chunks = profile.history_narrative_chunks(max_chunks: 6)

    payload = {
      post: {
        shortcode: post.shortcode,
        caption: post.caption,
        taken_at: post.taken_at&.iso8601,
        permalink: post.permalink_url,
        likes_count: post.likes_count,
        comments_count: post.comments_count,
        comments: post.instagram_profile_post_comments.recent_first.limit(25).map do |c|
          {
            author_username: c.author_username,
            body: c.body,
            commented_at: c.commented_at&.iso8601
          }
        end
      },
      author_profile: {
        username: profile.username,
        display_name: profile.display_name,
        bio: profile.bio,
        can_message: profile.can_message,
        tags: profile.profile_tags.pluck(:name).sort
      },
      rules: {
        require_manual_review: true,
        style: "gen_z_light",
        historical_narrative_text: history_narrative,
        historical_narrative_chunks: history_chunks
      }
    }

    run = Ai::Runner.new(account: account).analyze!(
      purpose: "post",
      analyzable: post,
      payload: payload,
      media: build_post_media_payload(post),
      media_fingerprint: media_fingerprint_for(post)
    )

    {
      "provider" => run[:provider].key,
      "model" => run.dig(:result, :model),
      "analysis" => run.dig(:result, :analysis)
    }
  end

  def build_post_media_payload(post)
    return { type: "none" } unless post.media.attached?

    blob = post.media.blob
    return { type: "none" } unless blob&.content_type.to_s.start_with?("image/")

    if blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES
      return { type: "image", content_type: blob.content_type, url: post.source_media_url.to_s }
    end

    data = blob.download
    {
      type: "image",
      content_type: blob.content_type,
      bytes: data,
      image_data_url: "data:#{blob.content_type};base64,#{Base64.strict_encode64(data)}"
    }
  rescue StandardError
    { type: "none" }
  end

  def media_fingerprint_for(post)
    return post.media_url_fingerprint.to_s if post.media_url_fingerprint.to_s.present?

    if post.media.attached?
      checksum = post.media.blob&.checksum.to_s
      return "blob:#{checksum}" if checksum.present?
    end

    url = post.source_media_url.to_s
    return Digest::SHA256.hexdigest(url) if url.present?

    nil
  end

  def encode_blob_to_data_url(blob)
    return nil unless blob
    return nil unless blob.content_type.to_s.start_with?("image/")
    return nil if blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES

    "data:#{blob.content_type};base64,#{Base64.strict_encode64(blob.download)}"
  rescue StandardError
    nil
  end

  def update_profile_demographics_from_analysis!(profile:, analysis:)
    return unless analysis.is_a?(Hash)

    demo = analysis["demographic_estimates"]
    demo = analysis["self_declared"] if !demo.is_a?(Hash) && analysis["self_declared"].is_a?(Hash)
    demo = {} unless demo.is_a?(Hash)

    attrs = {
      ai_persona_summary: analysis["summary"].to_s.presence || profile.ai_persona_summary,
      ai_last_analyzed_at: Time.current
    }

    age = integer_or_nil(demo["age"])
    age ||= integer_or_nil(analysis.dig("self_declared", "age"))
    age ||= inferred_age_from_text(profile: profile, analysis: analysis)
    attrs[:ai_estimated_age] = age if age.present?

    gender = demo["gender"].to_s.strip
    gender = analysis.dig("self_declared", "gender").to_s.strip if gender.blank?
    gender = inferred_gender_from_text(profile: profile, analysis: analysis) if gender.blank?
    attrs[:ai_estimated_gender] = gender if gender.present?

    location = demo["location"].to_s.strip
    location = analysis.dig("self_declared", "location").to_s.strip if location.blank?
    location = inferred_location_from_text(profile: profile, analysis: analysis) if location.blank?
    attrs[:ai_estimated_location] = location if location.present?

    attrs[:ai_age_confidence] = float_or_nil(demo["age_confidence"]) || (age.present? ? 0.35 : nil)
    attrs[:ai_gender_confidence] = float_or_nil(demo["gender_confidence"]) || (gender.present? ? 0.3 : nil)
    attrs[:ai_location_confidence] = float_or_nil(demo["location_confidence"]) || (location.present? ? 0.25 : nil)

    profile.update!(attrs)
  rescue StandardError
    nil
  end

  def aggregate_demographics_from_accumulated_json!(account:, profile:, latest_profile_analysis:)
    dataset = build_demographics_dataset(profile: profile, latest_profile_analysis: latest_profile_analysis)
    aggregated = Ai::ProfileDemographicsAggregator.new(account: account).aggregate!(dataset: dataset)
    return unless aggregated.is_a?(Hash) && aggregated[:ok] == true

    profile_inference = aggregated[:profile_inference].is_a?(Hash) ? aggregated[:profile_inference] : {}
    post_inferences = Array(aggregated[:post_inferences]).select { |entry| entry.is_a?(Hash) }

    persist_profile_demographic_inference!(
      profile: profile,
      profile_inference: profile_inference,
      source: aggregated[:source].to_s,
      error: aggregated[:error].to_s.presence
    )
    persist_profile_post_demographic_inferences!(
      profile: profile,
      profile_inference: profile_inference,
      post_inferences: post_inferences,
      source: aggregated[:source].to_s
    )
    persist_feed_post_demographic_inferences!(
      profile: profile,
      profile_inference: profile_inference,
      post_inferences: post_inferences,
      source: aggregated[:source].to_s
    )

    profile.record_event!(
      kind: "demographics_aggregated",
      external_id: "demographics_aggregated:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        source: aggregated[:source].to_s,
        profile_inference: profile_inference,
        post_inferences_count: post_inferences.length,
        profile_dataset_rows: dataset.dig(:analysis_pool, :profile_rows_count),
        post_dataset_rows: dataset.dig(:analysis_pool, :post_rows_count),
        aggregator_error: aggregated[:error].to_s.presence
      }
    )
  rescue StandardError
    nil
  end

  def build_demographics_dataset(profile:, latest_profile_analysis:)
    profile_runs = profile.ai_analyses.where(purpose: "profile", status: "succeeded").recent_first.limit(30)
    profile_post_runs = profile.instagram_profile_posts.where.not(analysis: nil).recent_first.limit(120)
    feed_post_runs = profile.instagram_account.instagram_posts.where(instagram_profile_id: profile.id).where.not(analysis: nil).recent_first.limit(120)

    profile_demographics = []

    if latest_profile_analysis.is_a?(Hash)
      profile_demographics << extract_demographics_from_analysis(latest_profile_analysis)
    end

    profile_runs.each do |row|
      extracted = extract_demographics_from_analysis(row.analysis)
      profile_demographics << extracted if extracted.present?
    end

    profile_insight_rows = profile.instagram_profile_insights.order(created_at: :desc).limit(20)
    profile_insight_rows.each do |insight|
      analysis = insight.raw_analysis
      extracted = extract_demographics_from_analysis(analysis)
      profile_demographics << extracted if extracted.present?
    end

    post_demographics = []

    profile_post_runs.each do |post|
      extracted = extract_demographics_from_analysis(post.analysis)
      next if extracted.blank?

      post_demographics << extracted.merge(shortcode: post.shortcode, source: "instagram_profile_posts")
    end

    feed_post_runs.each do |post|
      extracted = extract_demographics_from_analysis(post.analysis)
      next if extracted.blank?

      post_demographics << extracted.merge(shortcode: post.shortcode, source: "instagram_posts")
    end

    {
      profile: {
        username: profile.username,
        display_name: profile.display_name,
        bio: profile.bio,
        current_demographics: {
          age: profile.ai_estimated_age,
          age_confidence: profile.ai_age_confidence,
          gender: profile.ai_estimated_gender,
          gender_confidence: profile.ai_gender_confidence,
          location: profile.ai_estimated_location,
          location_confidence: profile.ai_location_confidence
        }
      },
      analysis_pool: {
        profile_demographics: profile_demographics,
        post_demographics: post_demographics,
        profile_rows_count: profile_demographics.length,
        post_rows_count: post_demographics.length
      }
    }
  end

  def extract_demographics_from_analysis(analysis)
    return {} unless analysis.is_a?(Hash)

    demo = analysis["demographic_estimates"].is_a?(Hash) ? analysis["demographic_estimates"] : {}
    declared = analysis["self_declared"].is_a?(Hash) ? analysis["self_declared"] : {}
    inferred = analysis["inferred_demographics"].is_a?(Hash) ? analysis["inferred_demographics"] : {}

    age = integer_or_nil(demo["age"]) || integer_or_nil(declared["age"]) || integer_or_nil(inferred["age"])
    gender = demo["gender"].to_s.strip.presence || declared["gender"].to_s.strip.presence || inferred["gender"].to_s.strip.presence
    location = demo["location"].to_s.strip.presence || declared["location"].to_s.strip.presence || inferred["location"].to_s.strip.presence

    {
      age: age,
      age_confidence: float_or_nil(demo["age_confidence"]) || float_or_nil(inferred["age_confidence"]),
      gender: normalize_unknown_string(gender),
      gender_confidence: float_or_nil(demo["gender_confidence"]) || float_or_nil(inferred["gender_confidence"]),
      location: normalize_unknown_string(location),
      location_confidence: float_or_nil(demo["location_confidence"]) || float_or_nil(inferred["location_confidence"]),
      evidence: analysis["evidence"].to_s.presence || demo["evidence"].to_s.presence
    }.compact
  end

  def persist_profile_demographic_inference!(profile:, profile_inference:, source:, error:)
    attrs = { ai_last_analyzed_at: Time.current }

    maybe_age = integer_or_nil(profile_inference[:age])
    maybe_age_conf = float_or_nil(profile_inference[:age_confidence])
    if should_replace_value?(current: profile.ai_estimated_age, candidate: maybe_age, current_confidence: profile.ai_age_confidence, candidate_confidence: maybe_age_conf)
      attrs[:ai_estimated_age] = maybe_age
      attrs[:ai_age_confidence] = maybe_age_conf if maybe_age_conf
    end

    maybe_gender = normalize_unknown_string(profile_inference[:gender])
    maybe_gender_conf = float_or_nil(profile_inference[:gender_confidence])
    if should_replace_value?(current: normalize_unknown_string(profile.ai_estimated_gender), candidate: maybe_gender, current_confidence: profile.ai_gender_confidence, candidate_confidence: maybe_gender_conf)
      attrs[:ai_estimated_gender] = maybe_gender
      attrs[:ai_gender_confidence] = maybe_gender_conf if maybe_gender_conf
    end

    maybe_location = normalize_unknown_string(profile_inference[:location])
    maybe_location_conf = float_or_nil(profile_inference[:location_confidence])
    if should_replace_value?(current: normalize_unknown_string(profile.ai_estimated_location), candidate: maybe_location, current_confidence: profile.ai_location_confidence, candidate_confidence: maybe_location_conf)
      attrs[:ai_estimated_location] = maybe_location
      attrs[:ai_location_confidence] = maybe_location_conf if maybe_location_conf
    end

    evidence = [ profile_inference[:evidence].to_s, profile_inference[:why].to_s, error.to_s ].reject(&:blank?).join(" | ")
    if evidence.present?
      attrs[:ai_persona_summary] = [ profile.ai_persona_summary.to_s.presence, evidence ].compact.join("\n")
    end

    profile.update!(attrs) if attrs.keys.length > 1 || attrs[:ai_persona_summary].present?
  end

  def persist_profile_post_demographic_inferences!(profile:, profile_inference:, post_inferences:, source:)
    by_shortcode = post_inferences.index_by { |entry| entry[:shortcode].to_s }

    profile.instagram_profile_posts.recent_first.limit(150).each do |post|
      post_hint = by_shortcode[post.shortcode.to_s]
      enrich_post_demographics!(
        record: post,
        profile_inference: profile_inference,
        post_hint: post_hint,
        source: source
      )
    end
  end

  def persist_feed_post_demographic_inferences!(profile:, profile_inference:, post_inferences:, source:)
    by_shortcode = post_inferences.index_by { |entry| entry[:shortcode].to_s }

    profile.instagram_account.instagram_posts.where(instagram_profile_id: profile.id).recent_first.limit(150).each do |post|
      post_hint = by_shortcode[post.shortcode.to_s]
      enrich_post_demographics!(
        record: post,
        profile_inference: profile_inference,
        post_hint: post_hint,
        source: source
      )
    end
  end

  def enrich_post_demographics!(record:, profile_inference:, post_hint:, source:)
    base = record.analysis.is_a?(Hash) ? record.analysis.deep_dup : {}
    inferred = base["inferred_demographics"].is_a?(Hash) ? base["inferred_demographics"].deep_dup : {}

    relevant = ActiveModel::Type::Boolean.new.cast(post_hint&.dig(:relevant))
    relevant ||= ActiveModel::Type::Boolean.new.cast(base["relevant"])

    age = integer_or_nil(post_hint&.dig(:age)) || integer_or_nil(profile_inference[:age])
    gender = normalize_unknown_string(post_hint&.dig(:gender)) || normalize_unknown_string(profile_inference[:gender])
    location = normalize_unknown_string(post_hint&.dig(:location)) || normalize_unknown_string(profile_inference[:location])
    confidence = float_or_nil(post_hint&.dig(:confidence)) || float_or_nil(profile_inference[:age_confidence]) || 0.3

    changed = false
    if inferred["age"].blank? && age.present?
      inferred["age"] = age
      changed = true
    end
    if normalize_unknown_string(inferred["gender"]).blank? && gender.present?
      inferred["gender"] = gender
      changed = true
    end
    if normalize_unknown_string(inferred["location"]).blank? && location.present?
      inferred["location"] = location
      changed = true
    end

    if changed
      inferred["confidence"] = confidence
      inferred["age_confidence"] = float_or_nil(profile_inference[:age_confidence]) if inferred["age_confidence"].blank?
      inferred["gender_confidence"] = float_or_nil(profile_inference[:gender_confidence]) if inferred["gender_confidence"].blank?
      inferred["location_confidence"] = float_or_nil(profile_inference[:location_confidence]) if inferred["location_confidence"].blank?
      inferred["relevant"] = relevant
      inferred["source"] = source.to_s.presence || "json_aggregator"
      inferred["updated_at"] = Time.current.utc.iso8601(3)
      inferred["evidence"] = post_hint&.dig(:evidence).to_s.presence || profile_inference[:evidence].to_s.presence

      base["inferred_demographics"] = inferred
      record.update!(analysis: base)
    end
  rescue StandardError
    nil
  end

  def should_replace_value?(current:, candidate:, current_confidence:, candidate_confidence:)
    return false if candidate.blank?
    return true if current.blank?

    current_unknown = normalize_unknown_string(current).blank?
    return true if current_unknown

    cand_conf = float_or_nil(candidate_confidence).to_f
    curr_conf = float_or_nil(current_confidence).to_f

    cand_conf > (curr_conf + 0.1)
  end

  def normalize_unknown_string(value)
    text = value.to_s.strip
    return nil if text.blank?
    return nil if %w[unknown n/a none null].include?(text.downcase)

    text
  end

  def inferred_age_from_text(profile:, analysis:)
    text = [ profile.bio.to_s, analysis["summary"].to_s ].join(" ").downcase
    return 21 if text.match?(/\b(student|college|university|campus|undergrad)\b/)
    return 17 if text.match?(/\b(high school|school life|class of 20\d{2})\b/)
    return 34 if text.match?(/\b(mom|dad|parent)\b/)

    26
  end

  def inferred_gender_from_text(profile:, analysis:)
    text = [ profile.bio.to_s, analysis["summary"].to_s ].join(" ").downcase
    return "female" if text.match?(/\b(she\/her|she her|woman|girl|mrs|ms)\b/)
    return "male" if text.match?(/\b(he\/him|he him|man|boy|mr)\b/)
    return "non-binary" if text.match?(/\b(they\/them|non[- ]?binary)\b/)

    "unknown"
  end

  def inferred_location_from_text(profile:, analysis:)
    text = [
      profile.bio.to_s,
      analysis["summary"].to_s,
      Array(analysis["languages"]).map { |l| l.is_a?(Hash) ? l["language"] : l }.join(" ")
    ].join(" ").downcase

    if (m = text.match(/(?:📍|based in|from)\s+([a-z][a-z\s,.-]{2,40})/))
      return m[1].to_s.split(/[|•]/).first.to_s.strip.titleize
    end

    return "United States" if text.match?(/\b(english|usa|us)\b/)
    return "India" if text.match?(/\b(hindi|india|indian)\b/)

    "unknown"
  end

  def integer_or_nil(value)
    return nil if value.blank?
    Integer(value)
  rescue StandardError
    nil
  end

  def float_or_nil(value)
    return nil if value.blank?
    Float(value)
  rescue StandardError
    nil
  end
end
