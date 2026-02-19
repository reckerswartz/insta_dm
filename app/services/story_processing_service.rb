require "json"
require "net/http"
require "uri"

class StoryProcessingService
  DEFAULT_MATCH_MIN_CONFIDENCE = ENV.fetch("STORY_FACE_MATCH_MIN_CONFIDENCE", "0.78").to_f

  def initialize(
    story:,
    force: false,
    face_detection_service: FaceDetectionService.new,
    face_embedding_service: FaceEmbeddingService.new,
    vector_matching_service: VectorMatchingService.new,
    user_profile_builder_service: UserProfileBuilderService.new,
    video_frame_extraction_service: VideoFrameExtractionService.new,
    video_audio_extraction_service: VideoAudioExtractionService.new,
    speech_transcription_service: SpeechTranscriptionService.new,
    video_metadata_service: VideoMetadataService.new,
    video_frame_change_detector_service: VideoFrameChangeDetectorService.new,
    content_understanding_service: StoryContentUnderstandingService.new,
    response_generation_service: ResponseGenerationService.new,
    face_identity_resolution_service: FaceIdentityResolutionService.new,
    match_min_confidence: nil
  )
    @story = story
    @force = ActiveModel::Type::Boolean.new.cast(force)
    @face_detection_service = face_detection_service
    @face_embedding_service = face_embedding_service
    @vector_matching_service = vector_matching_service
    @user_profile_builder_service = user_profile_builder_service
    @video_frame_extraction_service = video_frame_extraction_service
    @video_audio_extraction_service = video_audio_extraction_service
    @speech_transcription_service = speech_transcription_service
    @video_metadata_service = video_metadata_service
    @video_frame_change_detector_service = video_frame_change_detector_service
    @content_understanding_service = content_understanding_service
    @response_generation_service = response_generation_service
    @face_identity_resolution_service = face_identity_resolution_service
    @match_min_confidence = begin
      value = match_min_confidence.nil? ? DEFAULT_MATCH_MIN_CONFIDENCE : match_min_confidence.to_f
      value.negative? ? DEFAULT_MATCH_MIN_CONFIDENCE : value
    rescue StandardError
      DEFAULT_MATCH_MIN_CONFIDENCE
    end
  end

  def process!
    return @story if @story.processed? && !@force

    @story.update!(processing_status: "processing", processed: false)
    @story.instagram_story_faces.delete_all if @force

    media_payload = load_media_payload
    result =
      if media_payload[:media_type] == "video"
        process_video_story(media_payload)
      else
        process_image_story(media_payload)
      end

    persist_faces!(detected_faces: result[:faces], story_id: media_payload[:story_id], fallback_image_bytes: media_payload[:image_bytes])
    linked_face_count = @story.instagram_story_faces.where.not(instagram_story_person_id: nil).count
    unlinked_face_count = @story.instagram_story_faces.where(instagram_story_person_id: nil).count
    content_understanding = @content_understanding_service.build(
      media_type: media_payload[:media_type],
      detections: result[:detections],
      transcript_text: result[:transcript_text]
    )
    suggestions = @response_generation_service.generate(
      profile: @story.instagram_profile,
      content_understanding: content_understanding
    )

    metadata = (@story.metadata.is_a?(Hash) ? @story.metadata : {}).merge(
      "ocr_text" => content_understanding[:ocr_text].to_s,
      "location_tags" => Array(content_understanding[:locations]).uniq,
      "content_signals" => Array(content_understanding[:objects]).uniq,
      "mentions" => Array(content_understanding[:mentions]).uniq,
      "hashtags" => Array(content_understanding[:hashtags]).uniq,
      "transcript" => content_understanding[:transcript].to_s.presence,
      "face_count" => result[:faces].length,
      "linked_face_count" => linked_face_count,
      "unlinked_face_count" => unlinked_face_count,
      "min_match_confidence" => @match_min_confidence.round(3),
      "processing_path" => media_payload[:media_type],
      "generated_response_suggestions" => suggestions,
      "content_understanding" => content_understanding,
      "last_processed_at" => Time.current.iso8601,
      "pipeline_version" => "story_processing_v2",
      "processing_metadata" => result[:processing_metadata]
    )

    @story.update!(
      processed: true,
      processing_status: "processed",
      processed_at: Time.current,
      duration_seconds: result[:duration_seconds] || @story.duration_seconds,
      metadata: metadata
    )

    identity_resolution = @face_identity_resolution_service.resolve_for_story!(
      story: @story,
      extracted_usernames: (
        Array(content_understanding[:mentions]) +
        Array(content_understanding[:profile_handles]) +
        content_understanding[:ocr_text].to_s.scan(/@[a-zA-Z0-9._]{2,30}/)
      ),
      content_summary: content_understanding
    )
    if identity_resolution.is_a?(Hash) && identity_resolution[:summary].is_a?(Hash)
      story_meta = @story.metadata.is_a?(Hash) ? @story.metadata.deep_dup : {}
      story_meta["face_identity"] = identity_resolution[:summary]
      story_meta["participant_summary"] = identity_resolution[:summary][:participant_summary_text].to_s
      @story.update!(metadata: story_meta)
    end

    InstagramProfileEvent.broadcast_story_archive_refresh!(account: @story.instagram_account)

    @user_profile_builder_service.refresh!(profile: @story.instagram_profile)
    @story
  rescue StandardError => e
    fail_story!(error_message: e.message)
    raise
  end

  private

  def process_image_story(media_payload)
    detection = @face_detection_service.detect(media_payload: media_payload)
    faces = Array(detection[:faces]).map do |face|
      face.merge(image_bytes: media_payload[:image_bytes], frame_index: 0, timestamp_seconds: 0.0)
    end

    {
      detections: [ detection ],
      faces: faces,
      transcript_text: nil,
      duration_seconds: nil,
      processing_metadata: {
        source: "image_single_frame",
        detection_metadata: detection[:metadata]
      }
    }
  end

  def process_video_story(media_payload)
    mode = @video_frame_change_detector_service.classify(
      video_bytes: media_payload[:bytes],
      reference_id: media_payload[:story_id],
      content_type: media_payload[:content_type]
    )
    if mode[:processing_mode].to_s == "static_image" && mode[:frame_bytes].present?
      result = process_image_story(
        media_payload.merge(
          media_type: "image",
          image_bytes: mode[:frame_bytes]
        )
      )
      result[:duration_seconds] = mode[:duration_seconds] if mode[:duration_seconds].to_f.positive?
      result[:processing_metadata] = (result[:processing_metadata].is_a?(Hash) ? result[:processing_metadata] : {}).merge(
        source: "video_static_single_frame",
        frame_change_detection: mode[:metadata]
      )
      return result
    end

    probe =
      if mode[:duration_seconds].to_f.positive? || mode.dig(:metadata, :video_probe).is_a?(Hash)
        {
          duration_seconds: mode[:duration_seconds],
          metadata: mode.dig(:metadata, :video_probe).is_a?(Hash) ? mode.dig(:metadata, :video_probe) : {}
        }
      else
        @video_metadata_service.probe(
          video_bytes: media_payload[:bytes],
          story_id: media_payload[:story_id],
          content_type: media_payload[:content_type]
        )
      end
    frames_result = @video_frame_extraction_service.extract(
      video_bytes: media_payload[:bytes],
      story_id: media_payload[:story_id],
      content_type: media_payload[:content_type]
    )

    detections = []
    faces = []
    Array(frames_result[:frames]).each do |frame|
      detection = @face_detection_service.detect(
        media_payload: {
          story_id: media_payload[:story_id],
          media_type: "image",
          image_bytes: frame[:image_bytes]
        }
      )
      detections << detection.merge(frame_index: frame[:index], timestamp_seconds: frame[:timestamp_seconds])

      Array(detection[:faces]).each do |face|
        faces << face.merge(
          image_bytes: frame[:image_bytes],
          frame_index: frame[:index],
          timestamp_seconds: frame[:timestamp_seconds]
        )
      end
    end

    audio = @video_audio_extraction_service.extract(
      video_bytes: media_payload[:bytes],
      story_id: media_payload[:story_id],
      content_type: media_payload[:content_type]
    )
    transcript = @speech_transcription_service.transcribe(
      audio_bytes: audio[:audio_bytes],
      story_id: media_payload[:story_id]
    )

    {
      detections: detections,
      faces: faces,
      transcript_text: transcript[:transcript],
      duration_seconds: probe[:duration_seconds],
      processing_metadata: {
        source: "video_multistage",
        video_probe: probe[:metadata],
        frame_change_detection: mode[:metadata],
        frame_extraction: frames_result[:metadata],
        audio_extraction: audio[:metadata],
        transcription: transcript[:metadata]
      }
    }
  end

  def persist_faces!(detected_faces:, story_id:, fallback_image_bytes:)
    Array(detected_faces).each do |face|
      observation_signature = face_observation_signature(story_id: story_id, face: face)
      confidence = face[:confidence].to_f
      unless linkable_face_confidence?(confidence)
        persist_unlinked_story_face!(
          face: face,
          observation_signature: observation_signature,
          reason: "low_confidence"
        )
        next
      end

      face_image_bytes = face[:image_bytes].presence || fallback_image_bytes
      if face_image_bytes.blank?
        persist_unlinked_story_face!(
          face: face,
          observation_signature: observation_signature,
          reason: "face_image_missing"
        )
        next
      end

      embedding_payload = @face_embedding_service.embed(
        media_payload: {
          story_id: story_id,
          media_type: "image",
          image_bytes: face_image_bytes
        },
        face: face
      )
      vector = Array(embedding_payload[:vector]).map(&:to_f)
      if vector.empty?
        persist_unlinked_story_face!(
          face: face,
          observation_signature: observation_signature,
          reason: "embedding_unavailable"
        )
        next
      end

      match = @vector_matching_service.match_or_create!(
        account: @story.instagram_account,
        profile: @story.instagram_profile,
        embedding: vector,
        occurred_at: @story.taken_at || Time.current,
        observation_signature: observation_signature
      )
      update_person_face_attributes!(person: match[:person], face: face)

      attrs = {
        instagram_story_person: match[:person],
        role: match[:role].to_s.presence || "unknown",
        detector_confidence: face[:confidence].to_f,
        match_similarity: match[:similarity],
        embedding_version: embedding_payload[:version].to_s,
        embedding: vector,
        bounding_box: face[:bounding_box],
        metadata: story_face_metadata(
          face: face,
          observation_signature: observation_signature,
          link_status: "matched"
        )
      }
      attrs[:embedding_vector] = vector if InstagramStoryFace.column_names.include?("embedding_vector")
      @story.instagram_story_faces.create!(attrs)
    end
  end

  def face_observation_signature(story_id:, face:)
    bbox = face[:bounding_box].is_a?(Hash) ? face[:bounding_box] : {}
    [
      "story",
      story_id.to_s,
      face[:frame_index].to_i,
      face[:timestamp_seconds].to_f.round(3),
      bbox["x1"],
      bbox["y1"],
      bbox["x2"],
      bbox["y2"]
    ].map(&:to_s).join(":")
  end

  def linkable_face_confidence?(confidence)
    confidence.to_f >= @match_min_confidence
  end

  def persist_unlinked_story_face!(face:, observation_signature:, reason:)
    @story.instagram_story_faces.create!(
      instagram_story_person: nil,
      role: "unknown",
      detector_confidence: face[:confidence].to_f,
      match_similarity: nil,
      embedding_version: nil,
      embedding: nil,
      bounding_box: face[:bounding_box],
      metadata: story_face_metadata(
        face: face,
        observation_signature: observation_signature,
        link_status: "unlinked",
        link_skip_reason: reason
      )
    )
  rescue StandardError
    nil
  end

  def story_face_metadata(face:, observation_signature:, link_status:, link_skip_reason: nil)
    {
      frame_index: face[:frame_index],
      timestamp_seconds: face[:timestamp_seconds],
      landmarks: face[:landmarks],
      likelihoods: face[:likelihoods],
      age: face[:age],
      age_range: face[:age_range],
      gender: face[:gender],
      gender_score: face[:gender_score].to_f,
      observation_signature: observation_signature,
      link_status: link_status,
      link_skip_reason: link_skip_reason
    }.compact
  end

  def load_media_payload
    bytes = nil
    content_type = nil

    if @story.media.attached?
      bytes = @story.media.download
      content_type = @story.media.content_type.to_s
    end

    url = media_download_url
    if bytes.blank? && url.present?
      bytes = download_bytes!(url)
      content_type = infer_content_type_from_url(url, fallback: content_type)
    end

    raise "No media payload available for story_id=#{@story.story_id}" if bytes.blank?

    media_type = infer_media_type(
      story_media_type: @story.media_type,
      content_type: content_type
    )
    image_bytes = media_type == "image" ? bytes : nil

    {
      story_id: @story.story_id,
      media_type: media_type,
      bytes: bytes,
      content_type: content_type,
      image_bytes: image_bytes
    }
  end

  def media_download_url
    if @story.video?
      @story.video_url.to_s.presence || @story.media_url.to_s.presence || @story.image_url.to_s.presence
    else
      @story.image_url.to_s.presence || @story.media_url.to_s.presence
    end
  end

  def infer_media_type(story_media_type:, content_type:)
    return "video" if story_media_type.to_s == "video"
    return "video" if content_type.to_s.start_with?("video/")

    "image"
  end

  def infer_content_type_from_url(url, fallback:)
    return fallback.to_s if fallback.to_s.present?

    value = url.to_s.downcase
    return "video/mp4" if value.include?(".mp4")
    return "video/quicktime" if value.include?(".mov")
    return "image/png" if value.include?(".png")
    return "image/webp" if value.include?(".webp")
    return "image/jpeg" if value.include?(".jpg") || value.include?(".jpeg")

    "application/octet-stream"
  end

  def download_bytes!(url)
    uri = URI.parse(url)
    raise "Invalid media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "*/*"
    req["Referer"] = "https://www.instagram.com/"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 8
    http.read_timeout = 25

    response = http.request(req)
    raise "Media download failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body.to_s
  end

  def update_person_face_attributes!(person:, face:)
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

  def fail_story!(error_message:)
    metadata = (@story.metadata.is_a?(Hash) ? @story.metadata : {}).merge(
      "processing_error" => error_message.to_s,
      "failed_at" => Time.current.iso8601
    )
    @story.update(
      processing_status: "failed",
      processed: false,
      metadata: metadata
    )
    InstagramProfileEvent.broadcast_story_archive_refresh!(account: @story.instagram_account)
  rescue StandardError
    nil
  end
end
