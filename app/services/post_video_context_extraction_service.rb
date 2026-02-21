class PostVideoContextExtractionService
  MAX_VIDEO_BYTES = ENV.fetch("POST_VIDEO_CONTEXT_MAX_BYTES", 35 * 1024 * 1024).to_i
  MAX_DYNAMIC_INTELLIGENCE_BYTES = ENV.fetch("POST_VIDEO_DYNAMIC_INTELLIGENCE_MAX_BYTES", 20 * 1024 * 1024).to_i
  MAX_AUDIO_EXTRACTION_BYTES = ENV.fetch("POST_VIDEO_AUDIO_MAX_BYTES", 30 * 1024 * 1024).to_i
  MAX_AUDIO_DURATION_SECONDS = ENV.fetch("POST_VIDEO_AUDIO_MAX_DURATION_SECONDS", 180).to_i
  TRANSCRIPT_MAX_CHARS = ENV.fetch("POST_VIDEO_TRANSCRIPT_MAX_CHARS", 420).to_i
  TOPIC_LIMIT = ENV.fetch("POST_VIDEO_TOPIC_LIMIT", 30).to_i
  SIGNAL_LIMIT = ENV.fetch("POST_VIDEO_SIGNAL_LIMIT", 40).to_i

  def initialize(
    video_frame_change_detector_service: VideoFrameChangeDetectorService.new,
    video_metadata_service: VideoMetadataService.new,
    video_audio_extraction_service: VideoAudioExtractionService.new,
    speech_transcription_service: SpeechTranscriptionService.new,
    local_microservice_client: Ai::LocalMicroserviceClient.new,
    content_understanding_service: StoryContentUnderstandingService.new
  )
    @video_frame_change_detector_service = video_frame_change_detector_service
    @video_metadata_service = video_metadata_service
    @video_audio_extraction_service = video_audio_extraction_service
    @speech_transcription_service = speech_transcription_service
    @local_microservice_client = local_microservice_client
    @content_understanding_service = content_understanding_service
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

    audio = extract_audio_if_allowed(
      bytes: bytes,
      reference_id: reference_id,
      content_type: content_type,
      duration_seconds: duration_seconds,
      has_audio: has_audio
    )
    transcript = transcribe_audio_if_available(audio: audio, reference_id: reference_id)
    transcript_text = truncate_text(transcript[:transcript].to_s, max: TRANSCRIPT_MAX_CHARS)

    local_video_intelligence = extract_local_video_intelligence_if_allowed(
      bytes: bytes,
      reference_id: reference_id,
      static_video: static_video
    )
    static_frame_intelligence = extract_static_frame_intelligence_if_available(
      mode: mode,
      reference_id: reference_id,
      static_video: static_video
    )

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
      context_summary: context_summary(
        processing_mode: processing_mode,
        duration_seconds: duration_seconds,
        topics: topics,
        transcript: transcript_text
      ),
      metadata: {
        frame_change_detection: mode[:metadata].is_a?(Hash) ? mode[:metadata] : {},
        video_probe: probe_metadata,
        audio_extraction: audio[:metadata],
        transcription: transcript[:metadata],
        static_frame_intelligence: static_frame_intelligence[:metadata],
        local_video_intelligence: local_video_intelligence[:metadata]
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
    if static_video
      return {
        data: {},
        metadata: { reason: "static_video_routed_to_image" }
      }
    end
    if bytes.bytesize > MAX_DYNAMIC_INTELLIGENCE_BYTES
      return {
        data: {},
        metadata: { reason: "video_too_large_for_dynamic_intelligence" }
      }
    end

    data = @local_microservice_client.analyze_video_story_intelligence!(
      video_bytes: bytes,
      usage_context: {
        workflow: "post_analysis_pipeline",
        task: "video_context",
        reference_id: reference_id.to_s
      }
    )
    {
      data: data.is_a?(Hash) ? data : {},
      metadata: (data.is_a?(Hash) ? data["metadata"] : nil).is_a?(Hash) ? data["metadata"] : {}
    }
  rescue StandardError => e
    {
      data: {},
      metadata: {
        reason: "dynamic_intelligence_error",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    }
  end

  def extract_static_frame_intelligence_if_available(mode:, reference_id:, static_video:)
    unless static_video
      return {
        data: {},
        metadata: { reason: "dynamic_video_no_static_frame_analysis" }
      }
    end

    frame_bytes = mode[:frame_bytes].to_s.b
    if frame_bytes.blank?
      return {
        data: {},
        metadata: { reason: "static_frame_missing" }
      }
    end

    data = @local_microservice_client.detect_faces_and_ocr!(
      image_bytes: frame_bytes,
      usage_context: {
        workflow: "post_analysis_pipeline",
        task: "video_static_frame_context",
        reference_id: reference_id.to_s
      }
    )
    {
      data: data.is_a?(Hash) ? data : {},
      metadata: (data.is_a?(Hash) ? data["metadata"] : nil).is_a?(Hash) ? data["metadata"] : {}
    }
  rescue StandardError => e
    {
      data: {},
      metadata: {
        reason: "static_frame_intelligence_error",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
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
