class PostFaceRecognitionService
  def initialize(
    face_detection_service: FaceDetectionService.new,
    face_embedding_service: FaceEmbeddingService.new,
    vector_matching_service: VectorMatchingService.new,
    face_identity_resolution_service: FaceIdentityResolutionService.new
  )
    @face_detection_service = face_detection_service
    @face_embedding_service = face_embedding_service
    @vector_matching_service = vector_matching_service
    @face_identity_resolution_service = face_identity_resolution_service
  end

  def process!(post:)
    return { skipped: true, reason: "post_missing" } unless post
    return { skipped: true, reason: "media_missing" } unless post.media.attached?

    content_type = post.media.blob&.content_type.to_s
    return { skipped: true, reason: "unsupported_content_type", content_type: content_type } unless content_type.start_with?("image/")

    image_bytes = post.media.download
    detection = @face_detection_service.detect(
      media_payload: {
        story_id: "post:#{post.id}",
        image_bytes: image_bytes
      }
    )

    post.instagram_post_faces.delete_all
    matches = []

    Array(detection[:faces]).each do |face|
      embedding_payload = @face_embedding_service.embed(
        media_payload: {
          story_id: "post:#{post.id}",
          media_type: "image",
          image_bytes: image_bytes
        },
        face: face
      )
      vector = Array(embedding_payload[:vector]).map(&:to_f)
      next if vector.empty?

      match = @vector_matching_service.match_or_create!(
        account: post.instagram_account,
        profile: post.instagram_profile,
        embedding: vector,
        occurred_at: post.taken_at || Time.current
      )

      person = match[:person]
      update_person_face_attributes!(person: person, face: face)
      post.instagram_post_faces.create!(
        instagram_story_person: person,
        role: match[:role].to_s.presence || "unknown",
        detector_confidence: face[:confidence].to_f,
        match_similarity: match[:similarity],
        embedding_version: embedding_payload[:version].to_s,
        embedding: vector,
        bounding_box: face[:bounding_box],
        metadata: {
          landmarks: face[:landmarks],
          likelihoods: face[:likelihoods],
          age: face[:age],
          age_range: face[:age_range],
          gender: face[:gender],
          gender_score: face[:gender_score].to_f
        }
      )

      matches << {
        person_id: person.id,
        role: match[:role],
        label: person.label,
        similarity: match[:similarity]
      }.compact
    end

    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    metadata["face_recognition"] = {
      "face_count" => Array(detection[:faces]).length,
      "matched_people" => matches,
      "ocr_text" => detection[:ocr_text].to_s,
      "objects" => Array(detection[:content_signals]),
      "hashtags" => Array(detection[:hashtags]),
      "mentions" => Array(detection[:mentions]),
      "profile_handles" => Array(detection[:profile_handles]),
      "updated_at" => Time.current.iso8601
    }
    post.update!(metadata: metadata)

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
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      metadata["face_recognition"] = (metadata["face_recognition"].is_a?(Hash) ? metadata["face_recognition"] : {}).merge(
        "identity" => identity_resolution[:summary],
        "participant_summary" => identity_resolution[:summary][:participant_summary_text].to_s
      )
      post.update!(metadata: metadata)
    end

    {
      skipped: false,
      face_count: Array(detection[:faces]).length,
      matched_people: matches,
      identity_resolution: identity_resolution
    }
  rescue StandardError => e
    {
      skipped: true,
      reason: "recognition_error",
      error: e.message.to_s
    }
  end

  private

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
