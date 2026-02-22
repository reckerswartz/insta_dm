require "timeout"

class ProcessPostVideoAnalysisJob < PostAnalysisStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:video_analysis)

  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_VIDEO_MAX_DEFER_ATTEMPTS", 3).to_i.clamp(1, 12)
  VIDEO_EXTRACTION_PROFILE = ENV.fetch("POST_VIDEO_EXTRACTION_PROFILE", "lightweight_v1").to_s
  FAST_FAIL_ON_TIMEOUT = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("AI_VIDEO_FAST_FAIL_ON_TIMEOUT", "true")
  )

  private

  def step_key
    "video"
  end

  def resource_task_name
    "video"
  end

  def max_defer_attempts
    MAX_DEFER_ATTEMPTS
  end

  def timeout_seconds
    video_timeout_seconds
  end

  def step_failure_reason
    "video_analysis_failed"
  end

  def perform_step!(context:, pipeline_run_id:, options: {})
    profile = context[:profile]
    post = context[:post]

    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    payload = builder.video_payload
    media_fingerprint = builder.media_fingerprint(media: payload)

    if ActiveModel::Type::Boolean.new.cast(payload[:skipped])
      persist_video_analysis!(
        post: post,
        result: payload,
        media_fingerprint: media_fingerprint,
        cache_hit: false,
        cache_source: "skipped"
      )
      return payload.merge(cache_hit: false)
    end

    cached = reusable_video_analysis_for(post: post, media_fingerprint: media_fingerprint)
    if cached
      cached_result = cached[:result].merge(cache_hit: true)
      persist_video_analysis!(
        post: post,
        result: cached_result,
        media_fingerprint: media_fingerprint,
        cache_hit: true,
        cache_source: cached[:source]
      )
      return cached_result
    end

    result = PostVideoContextExtractionService.new.extract(
      video_bytes: payload[:video_bytes],
      reference_id: payload[:reference_id].to_s.presence || "post_media_#{post.id}",
      content_type: payload[:content_type]
    )

    result_with_cache = result.merge(cache_hit: false)
    persist_video_analysis!(
      post: post,
      result: result_with_cache,
      media_fingerprint: media_fingerprint,
      cache_hit: false,
      cache_source: "fresh_extraction"
    )
    result_with_cache
  end

  def step_completion_result(raw_result:, context:, options: {})
    {
      skipped: ActiveModel::Type::Boolean.new.cast(raw_result[:skipped]),
      processing_mode: raw_result[:processing_mode].to_s,
      static: ActiveModel::Type::Boolean.new.cast(raw_result[:static]),
      semantic_route: raw_result[:semantic_route].to_s.presence,
      duration_seconds: raw_result[:duration_seconds],
      has_audio: ActiveModel::Type::Boolean.new.cast(raw_result[:has_audio]),
      transcript_present: raw_result[:transcript].to_s.present?,
      topics_count: Array(raw_result[:topics]).length,
      cache_hit: ActiveModel::Type::Boolean.new.cast(raw_result[:cache_hit]),
      reason: raw_result[:reason].to_s.presence
    }.compact
  end

  def persist_video_analysis!(post:, result:, media_fingerprint:, cache_hit:, cache_source:)
    normalized = normalize_video_result(result)
    post.with_lock do
      post.reload
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}

      analysis["video_processing_mode"] = normalized[:processing_mode].to_s if normalized.key?(:processing_mode)
      analysis["video_static_detected"] = ActiveModel::Type::Boolean.new.cast(normalized[:static]) if normalized.key?(:static)
      analysis["video_semantic_route"] = normalized[:semantic_route].to_s if normalized[:semantic_route].to_s.present?
      analysis["video_duration_seconds"] = normalized[:duration_seconds] if normalized.key?(:duration_seconds)
      analysis["video_context_summary"] = normalized[:context_summary].to_s if normalized[:context_summary].to_s.present?
      analysis["transcript"] = normalized[:transcript].to_s if normalized[:transcript].to_s.present?
      analysis["video_topics"] = normalized[:topics] if normalized[:topics].is_a?(Array)
      analysis["video_objects"] = normalized[:objects] if normalized[:objects].is_a?(Array)
      analysis["video_scenes"] = normalized[:scenes] if normalized[:scenes].is_a?(Array)
      analysis["video_hashtags"] = normalized[:hashtags] if normalized[:hashtags].is_a?(Array)
      analysis["video_mentions"] = normalized[:mentions] if normalized[:mentions].is_a?(Array)
      analysis["video_profile_handles"] = normalized[:profile_handles] if normalized[:profile_handles].is_a?(Array)
      analysis["video_ocr_text"] = normalized[:ocr_text].to_s if normalized[:ocr_text].to_s.present?
      analysis["video_ocr_blocks"] = normalized[:ocr_blocks] if normalized[:ocr_blocks].is_a?(Array)
      analysis["video_media_fingerprint"] = media_fingerprint.to_s if media_fingerprint.to_s.present?
      analysis["video_extraction_profile"] = VIDEO_EXTRACTION_PROFILE

      analysis["topics"] = merge_strings(analysis["topics"], normalized[:topics], limit: 40)
      analysis["objects"] = merge_strings(analysis["objects"], normalized[:objects], limit: 50)
      analysis["hashtags"] = merge_strings(analysis["hashtags"], normalized[:hashtags], limit: 50)
      analysis["mentions"] = merge_strings(analysis["mentions"], normalized[:mentions], limit: 50)

      if analysis["ocr_text"].to_s.blank? && normalized[:ocr_text].to_s.present?
        analysis["ocr_text"] = normalized[:ocr_text].to_s
      end
      if Array(analysis["ocr_blocks"]).empty? && normalized[:ocr_blocks].is_a?(Array)
        analysis["ocr_blocks"] = normalized[:ocr_blocks].first(40)
      end

      metadata["video_processing"] = {
        "skipped" => ActiveModel::Type::Boolean.new.cast(normalized[:skipped]),
        "processing_mode" => normalized[:processing_mode].to_s,
        "static" => ActiveModel::Type::Boolean.new.cast(normalized[:static]),
        "semantic_route" => normalized[:semantic_route].to_s.presence,
        "duration_seconds" => normalized[:duration_seconds],
        "has_audio" => ActiveModel::Type::Boolean.new.cast(normalized[:has_audio]),
        "transcript" => normalized[:transcript].to_s.presence,
        "topics" => normalized[:topics],
        "objects" => normalized[:objects],
        "scenes" => normalized[:scenes],
        "hashtags" => normalized[:hashtags],
        "mentions" => normalized[:mentions],
        "profile_handles" => normalized[:profile_handles],
        "ocr_text" => normalized[:ocr_text].to_s.presence,
        "ocr_blocks" => normalized[:ocr_blocks],
        "context_summary" => normalized[:context_summary].to_s.presence,
        "metadata" => normalized[:metadata],
        "media_fingerprint" => media_fingerprint.to_s.presence,
        "extraction_profile" => VIDEO_EXTRACTION_PROFILE,
        "cache" => {
          "hit" => ActiveModel::Type::Boolean.new.cast(cache_hit),
          "source" => cache_source.to_s.presence || "unknown",
          "updated_at" => Time.current.iso8601(3)
        },
        "updated_at" => Time.current.iso8601(3)
      }.compact

      post.update!(analysis: analysis, metadata: metadata)
    end
  end

  def reusable_video_analysis_for(post:, media_fingerprint:)
    return nil if media_fingerprint.to_s.blank?

    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    video_meta = metadata["video_processing"]
    return nil unless video_meta.is_a?(Hash)
    return nil unless video_meta["media_fingerprint"].to_s == media_fingerprint.to_s
    return nil unless video_meta["extraction_profile"].to_s == VIDEO_EXTRACTION_PROFILE
    return nil if video_meta["processing_mode"].to_s.blank?

    {
      source: "post_metadata_video_processing",
      result: {
        skipped: ActiveModel::Type::Boolean.new.cast(video_meta["skipped"]),
        processing_mode: video_meta["processing_mode"].to_s,
        static: ActiveModel::Type::Boolean.new.cast(video_meta["static"]),
        semantic_route: video_meta["semantic_route"].to_s.presence,
        duration_seconds: video_meta["duration_seconds"],
        has_audio: ActiveModel::Type::Boolean.new.cast(video_meta["has_audio"]),
        transcript: video_meta["transcript"].to_s.presence,
        topics: Array(video_meta["topics"]).map(&:to_s),
        objects: Array(video_meta["objects"]).map(&:to_s),
        scenes: Array(video_meta["scenes"]).select { |row| row.is_a?(Hash) },
        hashtags: Array(video_meta["hashtags"]).map(&:to_s),
        mentions: Array(video_meta["mentions"]).map(&:to_s),
        profile_handles: Array(video_meta["profile_handles"]).map(&:to_s),
        ocr_text: video_meta["ocr_text"].to_s.presence,
        ocr_blocks: Array(video_meta["ocr_blocks"]).select { |row| row.is_a?(Hash) },
        context_summary: video_meta["context_summary"].to_s.presence,
        metadata: begin
          source = video_meta["metadata"].is_a?(Hash) ? video_meta["metadata"].deep_dup : {}
          source["cache"] = {
            "reused" => true,
            "source" => "post_metadata_video_processing"
          }
          source
        end
      }
    }
  rescue StandardError
    nil
  end

  def normalize_video_result(result)
    row = result.is_a?(Hash) ? result : {}
    {
      skipped: value_for(row, :skipped),
      processing_mode: value_for(row, :processing_mode).to_s.presence || "dynamic_video",
      static: value_for(row, :static),
      semantic_route: value_for(row, :semantic_route),
      duration_seconds: value_for(row, :duration_seconds),
      has_audio: value_for(row, :has_audio),
      transcript: value_for(row, :transcript),
      topics: normalized_strings(value_for(row, :topics), limit: 40),
      objects: normalized_strings(value_for(row, :objects), limit: 50),
      scenes: Array(value_for(row, :scenes)).select { |value| value.is_a?(Hash) }.first(50),
      hashtags: normalized_strings(value_for(row, :hashtags), limit: 50),
      mentions: normalized_strings(value_for(row, :mentions), limit: 50),
      profile_handles: normalized_strings(value_for(row, :profile_handles), limit: 50),
      ocr_text: value_for(row, :ocr_text),
      ocr_blocks: Array(value_for(row, :ocr_blocks)).select { |value| value.is_a?(Hash) }.first(80),
      context_summary: value_for(row, :context_summary),
      metadata: row[:metadata] || row["metadata"] || { reason: row[:reason] || row["reason"] }
    }
  end

  def normalized_strings(values, limit:)
    Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(limit)
  end

  def merge_strings(existing, incoming, limit:)
    normalized_strings(Array(existing) + Array(incoming), limit: limit)
  end

  def value_for(row, key)
    return row[key] if row.key?(key)
    return row[key.to_s] if row.key?(key.to_s)

    nil
  end

  def retryable_step_error?(error)
    return false if FAST_FAIL_ON_TIMEOUT && error.is_a?(Timeout::Error)

    true
  end

  def video_timeout_seconds
    ENV.fetch("AI_VIDEO_TIMEOUT_SECONDS", 120).to_i.clamp(20, 420)
  end
end
