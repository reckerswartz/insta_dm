class PostFaceRecognitionService
  DEFAULT_MATCH_MIN_CONFIDENCE = ENV.fetch("POST_FACE_MATCH_MIN_CONFIDENCE", "0.78").to_f

  def initialize(
    face_detection_service: FaceDetectionService.new,
    face_embedding_service: FaceEmbeddingService.new,
    vector_matching_service: VectorMatchingService.new,
    face_identity_resolution_service: FaceIdentityResolutionService.new,
    match_min_confidence: nil
  )
    @face_detection_service = face_detection_service
    @face_embedding_service = face_embedding_service
    @vector_matching_service = vector_matching_service
    @face_identity_resolution_service = face_identity_resolution_service
    @match_min_confidence = begin
      value = match_min_confidence.nil? ? DEFAULT_MATCH_MIN_CONFIDENCE : match_min_confidence.to_f
      value.negative? ? DEFAULT_MATCH_MIN_CONFIDENCE : value
    rescue StandardError
      DEFAULT_MATCH_MIN_CONFIDENCE
    end
  end

  def process!(post:)
    return { skipped: true, reason: "post_missing" } unless post
    return { skipped: true, reason: "media_missing" } unless post.media.attached?

    source_payload = load_face_detection_payload(post: post)
    if source_payload[:skipped]
      persist_face_recognition_metadata!(
        post: post,
        attributes: {
          "face_count" => post.instagram_post_faces.count,
          "matched_people" => [],
          "detection_source" => source_payload[:detection_source].to_s.presence || source_payload[:content_type].to_s.presence || "unknown",
          "detection_reason" => source_payload[:reason].to_s.presence || "face_detection_skipped",
          "detection_error" => source_payload[:error].to_s.presence,
          "updated_at" => Time.current.iso8601
        }.compact
      )
      return source_payload
    end

    image_bytes = source_payload[:image_bytes]
    detection = @face_detection_service.detect(
      media_payload: {
        story_id: "post:#{post.id}",
        image_bytes: image_bytes
      }
    )
    detection_metadata = detection[:metadata].is_a?(Hash) ? detection[:metadata] : {}
    detection_reason = detection_metadata[:reason].to_s.presence || detection_metadata["reason"].to_s.presence
    detection_error = detection_metadata[:error_message].to_s.presence || detection_metadata["error_message"].to_s.presence

    if detection_reason.present?
      persist_face_recognition_metadata!(
        post: post,
        attributes: {
          "face_count" => post.instagram_post_faces.count,
          "matched_people" => [],
          "detection_source" => source_payload[:detection_source],
          "detection_reason" => detection_reason,
          "detection_error" => detection_error,
          "detection_warnings" => Array(detection_metadata[:warnings] || detection_metadata["warnings"]).first(20),
          "updated_at" => Time.current.iso8601
        }.compact
      )
      return {
        skipped: true,
        reason: "face_detection_failed",
        detection_reason: detection_reason,
        detection_error: detection_error
      }
    end

    post.instagram_post_faces.delete_all
    matches = []
    linked_face_count = 0
    low_confidence_filtered_count = 0

    Array(detection[:faces]).each_with_index do |face, index|
      observation_signature = face_observation_signature(
        post: post,
        face: face,
        index: index,
        detection_source: source_payload[:detection_source]
      )
      confidence = face[:confidence].to_f

      unless linkable_face_confidence?(confidence)
        low_confidence_filtered_count += 1
        persist_unlinked_face!(
          post: post,
          face: face,
          observation_signature: observation_signature,
          source: source_payload[:detection_source],
          reason: "low_confidence"
        )
        next
      end

      embedding_payload = @face_embedding_service.embed(
        media_payload: {
          story_id: "post:#{post.id}",
          media_type: "image",
          image_bytes: image_bytes
        },
        face: face
      )
      vector = Array(embedding_payload[:vector]).map(&:to_f)
      if vector.empty?
        persist_unlinked_face!(
          post: post,
          face: face,
          observation_signature: observation_signature,
          source: source_payload[:detection_source],
          reason: "embedding_unavailable"
        )
        next
      end

      match = @vector_matching_service.match_or_create!(
        account: post.instagram_account,
        profile: post.instagram_profile,
        embedding: vector,
        occurred_at: post.taken_at || Time.current,
        observation_signature: observation_signature
      )

      person = match[:person]
      update_person_face_attributes!(person: person, face: face)
      post.instagram_post_faces.create!(
        instagram_story_person: person,
        role: match[:role].to_s.presence || "unknown",
        detector_confidence: confidence,
        match_similarity: match[:similarity],
        embedding_version: embedding_payload[:version].to_s,
        embedding: vector,
        bounding_box: face[:bounding_box],
        metadata: face_record_metadata(
          source: source_payload[:detection_source],
          face: face,
          observation_signature: observation_signature,
          link_status: "matched"
        )
      )
      linked_face_count += 1

      matches << {
        person_id: person.id,
        role: match[:role],
        label: person.label,
        similarity: match[:similarity],
        owner_match: match[:role].to_s == "primary_user",
        recurring_face: person.appearance_count.to_i > 1,
        appearances: person.appearance_count.to_i,
        real_person_status: person.real_person_status,
        identity_confidence: person.identity_confidence
      }.compact
    end

    total_detected_faces = Array(detection[:faces]).length
    persist_face_recognition_metadata!(
      post: post,
      attributes: {
      "face_count" => total_detected_faces,
      "linked_face_count" => linked_face_count,
      "unlinked_face_count" => [ total_detected_faces - linked_face_count, 0 ].max,
      "low_confidence_filtered_count" => low_confidence_filtered_count,
      "min_match_confidence" => @match_min_confidence.round(3),
      "matched_people" => matches,
      "detection_source" => source_payload[:detection_source],
      "ocr_text" => detection[:ocr_text].to_s,
      "objects" => Array(detection[:content_signals]),
      "hashtags" => Array(detection[:hashtags]),
      "mentions" => Array(detection[:mentions]),
      "profile_handles" => Array(detection[:profile_handles]),
      "detection_warnings" => Array(detection_metadata[:warnings] || detection_metadata["warnings"]).first(20),
      "updated_at" => Time.current.iso8601
    }.compact
    )

    identity_resolution = @face_identity_resolution_service.resolve_for_post!(
      post: post,
      extracted_usernames: (
        Array(detection[:mentions]) +
        Array(detection[:profile_handles]) +
        detection[:ocr_text].to_s.scan(/@[a-zA-Z0-9._]{2,30}/)
      ),
      content_summary: detection
    )

    if identity_resolution.is_a?(Hash) && identity_resolution[:summary].is_a?(Hash)
      persist_face_recognition_metadata!(
        post: post,
        attributes: {
        "identity" => identity_resolution[:summary],
        "participant_summary" => identity_resolution[:summary][:participant_summary_text].to_s
      }
      )
    end

    {
      skipped: false,
      face_count: total_detected_faces,
      linked_face_count: linked_face_count,
      low_confidence_filtered_count: low_confidence_filtered_count,
      matched_people: matches,
      identity_resolution: identity_resolution
    }
  rescue StandardError => e
    if post&.persisted?
      persist_face_recognition_metadata!(
        post: post,
        attributes: {
          "face_count" => post.instagram_post_faces.count,
          "matched_people" => [],
          "detection_source" => "post_face_recognition",
          "detection_reason" => "recognition_error",
          "detection_error" => e.message.to_s,
          "updated_at" => Time.current.iso8601
        }
      )
    end

    {
      skipped: true,
      reason: "recognition_error",
      error: e.message.to_s
    }
  end

  private

  def persist_face_recognition_metadata!(post:, attributes:)
    post.with_lock do
      post.reload
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      current = metadata["face_recognition"].is_a?(Hash) ? metadata["face_recognition"].deep_dup : {}
      metadata["face_recognition"] = current.merge(attributes.to_h.compact)
      post.update!(metadata: metadata)
    end
  rescue StandardError
    nil
  end

  def load_face_detection_payload(post:)
    content_type = post.media.blob&.content_type.to_s
    if content_type.start_with?("image/")
      return {
        skipped: false,
        image_bytes: post.media.download,
        detection_source: "post_media_image",
        content_type: content_type
      }
    end

    if content_type.start_with?("video/")
      if post.preview_image.attached?
        return {
          skipped: false,
          image_bytes: post.preview_image.download,
          detection_source: "post_preview_image",
          content_type: post.preview_image.blob&.content_type.to_s
        }
      end

      begin
        generated_preview = post.media.preview(resize_to_limit: [ 960, 960 ]).processed
        preview_blob = generated_preview.respond_to?(:image) ? generated_preview.image : nil
        return {
          skipped: false,
          image_bytes: generated_preview.download,
          detection_source: "post_generated_video_preview",
          content_type: preview_blob&.content_type.to_s.presence || "image/jpeg"
        }
      rescue StandardError
        return {
          skipped: true,
          reason: "video_preview_unavailable",
          content_type: content_type
        }
      end
    end

    {
      skipped: true,
      reason: "unsupported_content_type",
      content_type: content_type
    }
  rescue StandardError => e
    {
      skipped: true,
      reason: "media_load_error",
      error: e.message.to_s,
      content_type: content_type.to_s
    }
  end

  def face_observation_signature(post:, face:, index:, detection_source:)
    bbox = face[:bounding_box].is_a?(Hash) ? face[:bounding_box] : {}
    [
      "post",
      post.id,
      detection_source.to_s,
      index.to_i,
      bbox["x1"],
      bbox["y1"],
      bbox["x2"],
      bbox["y2"]
    ].map(&:to_s).join(":")
  end

  def linkable_face_confidence?(confidence)
    confidence.to_f >= @match_min_confidence
  end

  def persist_unlinked_face!(post:, face:, observation_signature:, source:, reason:)
    post.instagram_post_faces.create!(
      instagram_story_person: nil,
      role: "unknown",
      detector_confidence: face[:confidence].to_f,
      match_similarity: nil,
      embedding_version: nil,
      embedding: nil,
      bounding_box: face[:bounding_box],
      metadata: face_record_metadata(
        source: source,
        face: face,
        observation_signature: observation_signature,
        link_status: "unlinked",
        link_skip_reason: reason
      )
    )
  rescue StandardError
    nil
  end

  def face_record_metadata(source:, face:, observation_signature:, link_status:, link_skip_reason: nil)
    {
      source: source,
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
end
