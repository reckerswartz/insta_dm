class PostVideoContextExtractionService
  MAX_VIDEO_BYTES = ENV.fetch("POST_VIDEO_CONTEXT_MAX_BYTES", 35 * 1024 * 1024).to_i
  MAX_DYNAMIC_INTELLIGENCE_BYTES = ENV.fetch("POST_VIDEO_DYNAMIC_INTELLIGENCE_MAX_BYTES", 20 * 1024 * 1024).to_i
  MAX_AUDIO_EXTRACTION_BYTES = ENV.fetch("POST_VIDEO_AUDIO_MAX_BYTES", 30 * 1024 * 1024).to_i
  MAX_AUDIO_DURATION_SECONDS = ENV.fetch("POST_VIDEO_AUDIO_MAX_DURATION_SECONDS", 120).to_i
  TRANSCRIPT_MAX_CHARS = ENV.fetch("POST_VIDEO_TRANSCRIPT_MAX_CHARS", 320).to_i
  TOPIC_LIMIT = ENV.fetch("POST_VIDEO_TOPIC_LIMIT", 24).to_i
  SIGNAL_LIMIT = ENV.fetch("POST_VIDEO_SIGNAL_LIMIT", 30).to_i
  VISION_FRAME_SAMPLE_LIMIT = ENV.fetch("POST_VIDEO_VISION_FRAME_SAMPLE_LIMIT", 2).to_i.clamp(1, 8)
  LIGHTWEIGHT_MODE = ActiveModel::Type::Boolean.new.cast(ENV.fetch("POST_VIDEO_LIGHTWEIGHT_MODE", "true"))
  AUDIO_PRIORITY_MIN_WORDS = ENV.fetch("POST_VIDEO_AUDIO_PRIORITY_MIN_WORDS", "8").to_i.clamp(4, 80)
  MIN_STRUCTURED_SIGNALS_FOR_SKIP = ENV.fetch("POST_VIDEO_MIN_STRUCTURED_SIGNALS_FOR_SKIP", "2").to_i.clamp(1, 24)
  SKIP_DYNAMIC_VISION_WHEN_AUDIO_PRESENT = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("POST_VIDEO_SKIP_DYNAMIC_VISION_WHEN_AUDIO_PRESENT", "true")
  )
  DYNAMIC_KEYFRAME_LIMIT = ENV.fetch("POST_VIDEO_DYNAMIC_KEYFRAME_LIMIT", "2").to_i.clamp(1, 8)
  DYNAMIC_FRAME_INTERVAL_SECONDS = ENV.fetch("POST_VIDEO_DYNAMIC_FRAME_INTERVAL_SECONDS", "5.0").to_f.clamp(1.0, 20.0)
  def initialize(
    video_frame_change_detector_service: VideoFrameChangeDetectorService.new,
    video_metadata_service: VideoMetadataService.new,
    video_audio_extraction_service: VideoAudioExtractionService.new,
    speech_transcription_service: SpeechTranscriptionService.new,
    content_understanding_service: StoryContentUnderstandingService.new,
    video_frame_extraction_service: VideoFrameExtractionService.new,
    vision_understanding_service: Ai::VisionUnderstandingService.new
  )
    @video_frame_change_detector_service = video_frame_change_detector_service
    @video_metadata_service = video_metadata_service
    @video_audio_extraction_service = video_audio_extraction_service
    @speech_transcription_service = speech_transcription_service
    @content_understanding_service = content_understanding_service
    @video_frame_extraction_service = video_frame_extraction_service
    @vision_understanding_service = vision_understanding_service
  end

  def extract(video_bytes:, reference_id:, content_type:)
    bytes = video_bytes.to_s.b
    return skipped_result(reason: "video_bytes_missing") if bytes.blank?
    if bytes.bytesize > MAX_VIDEO_BYTES
      return skipped_result(
        reason: "video_too_large_for_context_extraction",
        byte_size: bytes.bytesize,
        max_bytes: MAX_VIDEO_BYTES
      )
    end

    mode = @video_frame_change_detector_service.classify(
      video_bytes: bytes,
      reference_id: reference_id.to_s,
      content_type: content_type
    )
    processing_mode = mode[:processing_mode].to_s.presence || "dynamic_video"
    static_video = processing_mode == "static_image"
    semantic_route = static_video ? "image" : "video"

    probe = build_probe(
      bytes: bytes,
      reference_id: reference_id,
      content_type: content_type,
      mode: mode
    )
    duration_seconds = probe[:duration_seconds]
    probe_metadata = probe[:metadata].is_a?(Hash) ? probe[:metadata] : {}
    has_audio = ActiveModel::Type::Boolean.new.cast(probe_metadata["has_audio"] || probe_metadata[:has_audio])

    parallel_branches = extract_parallel_branches(
      bytes: bytes,
      reference_id: reference_id,
      content_type: content_type,
      duration_seconds: duration_seconds,
      has_audio: has_audio,
      static_video: static_video,
      mode: mode
    )
    audio = parallel_branches[:audio]
    transcript = parallel_branches[:transcript]
    transcript_text = truncate_text(transcript[:transcript].to_s, max: TRANSCRIPT_MAX_CHARS)
    local_video_intelligence = parallel_branches[:local_video_intelligence]
    static_frame_intelligence = parallel_branches[:static_frame_intelligence]

    detections =
      detections_from_static_frame_intelligence(static_frame_intelligence: static_frame_intelligence) +
      detections_from_local_intelligence(local_video_intelligence: local_video_intelligence)
    understanding = @content_understanding_service.build(
      media_type: semantic_route,
      detections: detections,
      transcript_text: transcript_text
    )

    topics = normalize_string_array(understanding[:topics], limit: TOPIC_LIMIT)
    objects = normalize_string_array(understanding[:objects], limit: SIGNAL_LIMIT)
    hashtags = normalize_string_array(understanding[:hashtags], limit: SIGNAL_LIMIT)
    mentions = normalize_string_array(understanding[:mentions], limit: SIGNAL_LIMIT)
    profile_handles = normalize_string_array(understanding[:profile_handles], limit: SIGNAL_LIMIT)
    vision_precheck = lightweight_vision_precheck(
      static_video: static_video,
      transcript_text: transcript_text,
      topics: topics,
      objects: objects
    )
    vision_understanding =
      if ActiveModel::Type::Boolean.new.cast(vision_precheck[:skip])
        skipped_vision_result(reason: vision_precheck[:reason], precheck: vision_precheck)
      else
        enrich_with_vision_model(
          bytes: bytes,
          mode: mode,
          reference_id: reference_id,
          content_type: content_type,
          static_video: static_video,
          semantic_route: semantic_route,
          transcript_text: transcript_text,
          topics: topics,
          objects: objects
        )
      end
    topics = merge_unique_strings(topics, vision_understanding[:topics], limit: TOPIC_LIMIT)
    objects = merge_unique_strings(objects, vision_understanding[:objects], limit: SIGNAL_LIMIT)
    context_summary_text = vision_understanding[:summary].to_s.presence || context_summary(
      processing_mode: processing_mode,
      duration_seconds: duration_seconds,
      topics: topics,
      transcript: transcript_text
    )

    {
      skipped: false,
      processing_mode: processing_mode,
      static: ActiveModel::Type::Boolean.new.cast(mode[:static]) || static_video,
      semantic_route: semantic_route,
      duration_seconds: duration_seconds,
      has_audio: has_audio,
      transcript: transcript_text.presence,
      topics: topics,
      objects: objects,
      object_detections: normalize_hash_array(understanding[:object_detections], limit: SIGNAL_LIMIT),
      face_count: understanding[:faces].to_i,
      people: [],
      scenes: normalize_hash_array(understanding[:scenes], limit: SIGNAL_LIMIT),
      hashtags: hashtags,
      mentions: mentions,
      profile_handles: profile_handles,
      ocr_text: understanding[:ocr_text].to_s.presence,
      ocr_blocks: normalize_hash_array(understanding[:ocr_blocks], limit: SIGNAL_LIMIT),
      context_summary: context_summary_text,
      metadata: {
        frame_change_detection: mode[:metadata].is_a?(Hash) ? mode[:metadata] : {},
        video_probe: probe_metadata,
        audio_extraction: audio[:metadata],
        transcription: transcript[:metadata],
        static_frame_intelligence: static_frame_intelligence[:metadata],
        local_video_intelligence: local_video_intelligence[:metadata],
        parallel_execution: parallel_branches[:parallel_execution],
        lightweight_preanalysis: vision_precheck,
        vision_understanding: vision_understanding[:metadata]
      }
    }
  rescue StandardError => e
    skipped_result(
      reason: "video_context_extraction_error",
      error_class: e.class.name,
      error_message: e.message.to_s
    )
  end

  private

  def extract_parallel_branches(bytes:, reference_id:, content_type:, duration_seconds:, has_audio:, static_video:, mode:)
    started_at = monotonic_time
    errors = {}
    audio_thread = Thread.new do
      parallel_audio_branch(
        bytes: bytes,
        reference_id: reference_id,
        content_type: content_type,
        duration_seconds: duration_seconds,
        has_audio: has_audio
      )
    end
    visual_thread = Thread.new do
      parallel_visual_branch(
        bytes: bytes,
        reference_id: reference_id,
        static_video: static_video,
        mode: mode
      )
    end

    audio_branch = resolve_parallel_branch(thread: audio_thread, key: :audio_pipeline, errors: errors) do
      {
        audio: empty_audio(reason: "audio_pipeline_parallel_error"),
        transcript: empty_transcript(reason: "audio_pipeline_parallel_error")
      }
    end
    visual_branch = resolve_parallel_branch(thread: visual_thread, key: :visual_pipeline, errors: errors) do
      {
        local_video_intelligence: {
          data: {},
          metadata: { reason: "visual_pipeline_parallel_error" }
        },
        static_frame_intelligence: {
          data: {},
          metadata: { reason: "visual_pipeline_parallel_error" }
        }
      }
    end

    {
      audio: audio_branch[:audio].is_a?(Hash) ? audio_branch[:audio] : empty_audio(reason: "audio_pipeline_missing"),
      transcript: audio_branch[:transcript].is_a?(Hash) ? audio_branch[:transcript] : empty_transcript(reason: "transcript_pipeline_missing"),
      local_video_intelligence: visual_branch[:local_video_intelligence].is_a?(Hash) ? visual_branch[:local_video_intelligence] : { data: {}, metadata: { reason: "visual_pipeline_missing" } },
      static_frame_intelligence: visual_branch[:static_frame_intelligence].is_a?(Hash) ? visual_branch[:static_frame_intelligence] : { data: {}, metadata: { reason: "visual_pipeline_missing" } },
      parallel_execution: {
        enabled: true,
        branch_count: 2,
        duration_ms: ((monotonic_time - started_at) * 1000.0).round,
        errors: errors.presence
      }.compact
    }
  end

  def parallel_audio_branch(bytes:, reference_id:, content_type:, duration_seconds:, has_audio:)
    audio = extract_audio_if_allowed(
      bytes: bytes,
      reference_id: reference_id,
      content_type: content_type,
      duration_seconds: duration_seconds,
      has_audio: has_audio
    )
    transcript = transcribe_audio_if_available(audio: audio, reference_id: reference_id)
    {
      audio: audio,
      transcript: transcript
    }
  end

  def parallel_visual_branch(bytes:, reference_id:, static_video:, mode:)
    {
      local_video_intelligence: extract_local_video_intelligence_if_allowed(
        bytes: bytes,
        reference_id: reference_id,
        static_video: static_video
      ),
      static_frame_intelligence: extract_static_frame_intelligence_if_available(
        mode: mode,
        reference_id: reference_id,
        static_video: static_video
      )
    }
  end

  def resolve_parallel_branch(thread:, key:, errors:)
    thread.value
  rescue StandardError => e
    errors[key] = {
      error_class: e.class.name,
      error_message: e.message.to_s
    }
    yield
  ensure
    begin
      thread&.join(0.01)
    rescue StandardError
      nil
    end
  end

  def build_probe(bytes:, reference_id:, content_type:, mode:)
    probe_metadata = mode.dig(:metadata, :video_probe)
    probe_duration = mode[:duration_seconds]

    if probe_metadata.is_a?(Hash) && (probe_duration.to_f.positive? || probe_metadata.present?)
      return {
        duration_seconds: probe_duration,
        metadata: probe_metadata
      }
    end

    @video_metadata_service.probe(
      video_bytes: bytes,
      story_id: reference_id.to_s,
      content_type: content_type
    )
  rescue StandardError => e
    {
      duration_seconds: nil,
      metadata: {
        reason: "video_probe_failed",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    }
  end

  def extract_audio_if_allowed(bytes:, reference_id:, content_type:, duration_seconds:, has_audio:)
    return empty_audio(reason: "no_audio_stream") unless has_audio
    if bytes.bytesize > MAX_AUDIO_EXTRACTION_BYTES
      return empty_audio(reason: "video_too_large_for_audio_extraction")
    end
    if duration_seconds.to_f.positive? && duration_seconds.to_f > MAX_AUDIO_DURATION_SECONDS
      return empty_audio(reason: "video_too_long_for_audio_extraction")
    end

    @video_audio_extraction_service.extract(
      video_bytes: bytes,
      story_id: reference_id.to_s,
      content_type: content_type
    )
  rescue StandardError => e
    empty_audio(reason: "audio_extraction_error", error_class: e.class.name, error_message: e.message.to_s)
  end

  def transcribe_audio_if_available(audio:, reference_id:)
    audio_bytes = audio[:audio_bytes].to_s.b
    return empty_transcript(reason: "audio_unavailable") if audio_bytes.blank?

    @speech_transcription_service.transcribe(
      audio_bytes: audio_bytes,
      story_id: reference_id.to_s
    )
  rescue StandardError => e
    empty_transcript(reason: "transcription_error", error_class: e.class.name, error_message: e.message.to_s)
  end

  def extract_local_video_intelligence_if_allowed(bytes:, reference_id:, static_video:)
    {
      data: {},
      metadata: { reason: "local_dynamic_intelligence_disabled" }
    }
  end

  def extract_static_frame_intelligence_if_available(mode:, reference_id:, static_video:)
    {
      data: {},
      metadata: { reason: "local_static_frame_intelligence_disabled" }
    }
  end

  def detections_from_static_frame_intelligence(static_frame_intelligence:)
    data = static_frame_intelligence[:data].is_a?(Hash) ? static_frame_intelligence[:data] : {}
    return [] if data.empty?

    [ {
      faces: Array(data["faces"]).select { |row| row.is_a?(Hash) },
      content_signals: Array(data["content_labels"]).map(&:to_s),
      object_detections: Array(data["object_detections"]).select { |row| row.is_a?(Hash) },
      scenes: Array(data["scenes"]).select { |row| row.is_a?(Hash) },
      location_tags: Array(data["location_tags"]).map(&:to_s),
      ocr_text: data["ocr_text"].to_s,
      ocr_blocks: Array(data["ocr_blocks"]).select { |row| row.is_a?(Hash) },
      mentions: Array(data["mentions"]).map(&:to_s),
      hashtags: Array(data["hashtags"]).map(&:to_s),
      profile_handles: Array(data["profile_handles"]).map(&:to_s)
    } ]
  end

  def detections_from_local_intelligence(local_video_intelligence:)
    data = local_video_intelligence[:data].is_a?(Hash) ? local_video_intelligence[:data] : {}
    return [] if data.empty?

    [ {
      content_signals: Array(data["content_labels"]).map(&:to_s),
      object_detections: Array(data["object_detections"]).select { |row| row.is_a?(Hash) },
      scenes: Array(data["scenes"]).select { |row| row.is_a?(Hash) },
      ocr_text: data["ocr_text"].to_s,
      ocr_blocks: Array(data["ocr_blocks"]).select { |row| row.is_a?(Hash) },
      mentions: Array(data["mentions"]).map(&:to_s),
      hashtags: Array(data["hashtags"]).map(&:to_s),
      profile_handles: Array(data["profile_handles"]).map(&:to_s)
    } ]
  end

  def context_summary(processing_mode:, duration_seconds:, topics:, transcript:)
    parts = []
    if processing_mode.to_s == "static_image"
      parts << "Static visual video detected and routed through image-style analysis."
    end
    if duration_seconds.to_f.positive?
      parts << "Duration #{duration_seconds.to_f.round(2)}s."
    end
    if topics.any?
      parts << "Topics: #{topics.first(6).join(', ')}."
    end
    if transcript.to_s.present?
      parts << "Audio transcript: #{truncate_text(transcript, max: 140)}."
    end

    text = parts.join(" ").strip
    text.presence
  end

  def enrich_with_vision_model(bytes:, mode:, reference_id:, content_type:, static_video:, semantic_route:, transcript_text:, topics:, objects:)
    unless @vision_understanding_service.respond_to?(:enabled?) && @vision_understanding_service.enabled?
      return {
        summary: nil,
        topics: [],
        objects: [],
        metadata: {
          status: "unavailable",
          source: "ollama_vision",
          reason: "vision_understanding_disabled"
        }
      }
    end

    frame_payload = vision_frame_payload(
      bytes: bytes,
      mode: mode,
      reference_id: reference_id,
      content_type: content_type,
      static_video: static_video
    )
    frame_bytes = frame_payload[:frames]
    return {
      summary: nil,
      topics: [],
      objects: [],
      metadata: {
        status: "unavailable",
        source: "ollama_vision",
        reason: frame_payload[:reason].to_s.presence || "vision_frame_payload_missing",
        frame_count: frame_bytes.length
      }.compact
    } if frame_bytes.empty?

    vision = @vision_understanding_service.summarize(
      image_bytes_list: frame_bytes,
      transcript: transcript_text,
      candidate_topics: Array(topics) + Array(objects),
      media_type: semantic_route
    )
    metadata = vision[:metadata].is_a?(Hash) ? vision[:metadata].dup : {}
    metadata[:frame_count] = frame_bytes.length
    metadata[:frame_source] = frame_payload[:source].to_s.presence || "unknown"
    metadata[:frame_extraction] = frame_payload[:metadata] if frame_payload[:metadata].is_a?(Hash)

    {
      summary: vision[:summary].to_s.presence,
      topics: normalize_string_array(vision[:topics], limit: TOPIC_LIMIT),
      objects: normalize_string_array(vision[:objects], limit: SIGNAL_LIMIT),
      metadata: metadata
    }
  rescue StandardError => e
    {
      summary: nil,
      topics: [],
      objects: [],
      metadata: {
        status: "unavailable",
        source: "ollama_vision",
        reason: "vision_enrichment_error",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    }
  end

  def lightweight_vision_precheck(static_video:, transcript_text:, topics:, objects:)
    transcript_words = word_count(transcript_text)
    structured_signal_count = normalize_string_array(Array(topics) + Array(objects), limit: SIGNAL_LIMIT).length

    skip = false
    reason = nil

    if !LIGHTWEIGHT_MODE
      reason = "lightweight_mode_disabled"
    elsif static_video
      reason = "static_video_visual_enrichment_allowed"
    elsif structured_signal_count >= MIN_STRUCTURED_SIGNALS_FOR_SKIP
      skip = true
      reason = "structured_signals_sufficient"
    elsif SKIP_DYNAMIC_VISION_WHEN_AUDIO_PRESENT && transcript_words >= AUDIO_PRIORITY_MIN_WORDS
      skip = true
      reason = "audio_priority_sufficient"
    end

    {
      skip: skip,
      reason: reason,
      lightweight_mode: LIGHTWEIGHT_MODE,
      static_video: ActiveModel::Type::Boolean.new.cast(static_video),
      transcript_word_count: transcript_words,
      structured_signal_count: structured_signal_count,
      audio_priority_threshold_words: AUDIO_PRIORITY_MIN_WORDS,
      structured_signal_threshold: MIN_STRUCTURED_SIGNALS_FOR_SKIP,
      skip_dynamic_vision_when_audio_present: SKIP_DYNAMIC_VISION_WHEN_AUDIO_PRESENT
    }
  rescue StandardError
    {
      skip: false,
      reason: "lightweight_precheck_error",
      lightweight_mode: LIGHTWEIGHT_MODE
    }
  end

  def skipped_vision_result(reason:, precheck:)
    {
      summary: nil,
      topics: [],
      objects: [],
      metadata: {
        status: "skipped",
        source: "ollama_vision",
        reason: reason.to_s.presence || "lightweight_preanalysis_skip",
        precheck: precheck
      }.compact
    }
  end

  def word_count(value)
    value.to_s.scan(/[a-zA-Z0-9']+/).length
  end

  def vision_frame_payload(bytes:, mode:, reference_id:, content_type:, static_video:)
    if static_video
      frame = static_frame_bytes(mode)
      return {
        frames: [ frame ],
        source: "frame_change_detector_static_frame",
        metadata: {
          static: true
        }
      } if frame.present?
    end

    duration_seconds = mode[:duration_seconds].to_f
    keyframe_limit = [ VISION_FRAME_SAMPLE_LIMIT, DYNAMIC_KEYFRAME_LIMIT ].min
    keyframe_timestamps = dynamic_vision_timestamps(duration_seconds: duration_seconds, limit: keyframe_limit)
    extracted = @video_frame_extraction_service.extract(
      video_bytes: bytes,
      story_id: reference_id.to_s,
      content_type: content_type,
      max_frames: VISION_FRAME_SAMPLE_LIMIT,
      interval_seconds: DYNAMIC_FRAME_INTERVAL_SECONDS,
      timestamps_seconds: keyframe_timestamps,
      key_frames_only: true
    )
    extraction_metadata = extracted[:metadata].is_a?(Hash) ? extracted[:metadata] : {}
    frames = frame_bytes_from_extraction(extracted).first(VISION_FRAME_SAMPLE_LIMIT)

    if frames.empty?
      fallback = @video_frame_extraction_service.extract(
        video_bytes: bytes,
        story_id: reference_id.to_s,
        content_type: content_type,
        max_frames: VISION_FRAME_SAMPLE_LIMIT,
        interval_seconds: DYNAMIC_FRAME_INTERVAL_SECONDS
      )
      fallback_metadata = fallback[:metadata].is_a?(Hash) ? fallback[:metadata] : {}
      frames = frame_bytes_from_extraction(fallback).first(VISION_FRAME_SAMPLE_LIMIT)
      extraction_metadata = extraction_metadata.merge(
        fallback: fallback_metadata
      ).compact
    end

    {
      frames: frames,
      source: "ffmpeg_frame_sampling",
      reason: extraction_metadata[:reason] || extraction_metadata["reason"],
      metadata: extraction_metadata
    }
  rescue StandardError => e
    {
      frames: [],
      source: "ffmpeg_frame_sampling",
      reason: "frame_sampling_error",
      metadata: {
        reason: "frame_sampling_error",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    }
  end

  def frame_bytes_from_extraction(extracted)
    Array(extracted[:frames]).filter_map do |row|
      payload = row.is_a?(Hash) ? row : {}
      frame = payload[:image_bytes].to_s.b
      frame = payload["image_bytes"].to_s.b if frame.blank?
      frame.presence
    end
  end

  def dynamic_vision_timestamps(duration_seconds:, limit:)
    count = limit.to_i.clamp(1, 8)
    duration = duration_seconds.to_f
    return [ 0.0 ].first(count) if duration <= 0.0

    candidates = [ 0.0 ]
    candidates << (duration / 2.0)
    candidates << [ duration - 0.25, 0.0 ].max
    while candidates.length < count
      offset = (DYNAMIC_FRAME_INTERVAL_SECONDS * candidates.length.to_f)
      candidates << [ offset, [ duration - 0.25, 0.0 ].max ].min
    end
    candidates
      .map { |value| value.round(3) }
      .uniq
      .first(count)
  rescue StandardError
    [ 0.0 ].first(limit.to_i.clamp(1, 8))
  end

  def static_frame_bytes(mode)
    value = mode[:frame_bytes]
    value = mode["frame_bytes"] if value.blank? && mode.is_a?(Hash)
    raw = value.to_s.b
    raw.presence
  end

  def merge_unique_strings(existing, incoming, limit:)
    normalize_string_array(Array(existing) + Array(incoming), limit: limit)
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rescue StandardError
    Time.current.to_f
  end

  def normalize_string_array(values, limit:)
    Array(values)
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .first(limit)
  end

  def normalize_hash_array(values, limit:)
    Array(values).select { |row| row.is_a?(Hash) }.first(limit)
  end

  def truncate_text(value, max:)
    text = value.to_s.strip
    return text if text.length <= max

    "#{text.byteslice(0, max)}..."
  end

  def empty_audio(reason:, error_class: nil, error_message: nil)
    {
      audio_bytes: nil,
      content_type: nil,
      metadata: {
        source: "video_audio_extraction",
        reason: reason.to_s,
        error_class: error_class.to_s.presence,
        error_message: error_message.to_s.presence
      }.compact
    }
  end

  def empty_transcript(reason:, error_class: nil, error_message: nil)
    {
      transcript: nil,
      metadata: {
        source: "speech_transcription",
        reason: reason.to_s,
        error_class: error_class.to_s.presence,
        error_message: error_message.to_s.presence
      }.compact
    }
  end

  def skipped_result(reason:, byte_size: nil, max_bytes: nil, error_class: nil, error_message: nil)
    {
      skipped: true,
      processing_mode: "dynamic_video",
      static: false,
      semantic_route: "video",
      duration_seconds: nil,
      has_audio: nil,
      transcript: nil,
      topics: [],
      objects: [],
      object_detections: [],
      face_count: 0,
      people: [],
      scenes: [],
      hashtags: [],
      mentions: [],
      profile_handles: [],
      ocr_text: nil,
      ocr_blocks: [],
      context_summary: nil,
      metadata: {
        reason: reason.to_s,
        byte_size: byte_size,
        max_bytes: max_bytes,
        error_class: error_class.to_s.presence,
        error_message: error_message.to_s.presence
      }.compact
    }
  end
end
