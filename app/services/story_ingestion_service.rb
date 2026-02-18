class StoryIngestionService
  def initialize(account:, profile:, enqueue_processing: true)
    @account = account
    @profile = profile
    @enqueue_processing = enqueue_processing
  end

  def ingest!(story:, source_event: nil, bytes: nil, content_type: nil, filename: nil, force_reprocess: false)
    story_id = story[:story_id].to_s.strip
    raise ArgumentError, "story_id is required" if story_id.blank?

    record = InstagramStory.find_or_initialize_by(instagram_profile: @profile, story_id: story_id)
    existing_story_record = record.persisted?
    record.instagram_account = @account
    record.source_event = source_event if source_event.present?
    record.media_type = story[:media_type].to_s.presence || infer_media_type(content_type: content_type)
    record.media_url = story[:media_url].to_s.presence
    record.image_url = story[:image_url].to_s.presence
    record.video_url = story[:video_url].to_s.presence
    record.taken_at = story[:taken_at] if story[:taken_at].present?
    record.expires_at = story[:expiring_at] if story[:expiring_at].present?
    record.duration_seconds = extract_duration_seconds(story: story, current: record.duration_seconds)
    record.metadata = merged_metadata(
      existing: record.metadata,
      story: story,
      filename: filename,
      content_type: content_type,
      media_bytes: bytes&.bytesize,
      existing_story_record: existing_story_record
    )

    if record.new_record? || force_reprocess
      record.processed = false
      record.processing_status = "pending"
      record.processed_at = nil
    end

    record.save!
    attach_media!(record: record, bytes: bytes, content_type: content_type, filename: filename) if bytes.present?
    enqueue_processing!(record: record, force_reprocess: force_reprocess)
    record
  end

  private

  def infer_media_type(content_type:)
    value = content_type.to_s.downcase
    return "video" if value.start_with?("video/")
    return "image" if value.start_with?("image/")

    nil
  end

  def merged_metadata(existing:, story:, filename:, content_type:, media_bytes:, existing_story_record:)
    current = existing.is_a?(Hash) ? existing : {}
    current.merge(
      "story_payload" => {
        "caption" => story[:caption].to_s,
        "permalink" => story[:permalink].to_s
      },
      "media_filename" => filename.to_s,
      "media_content_type" => content_type.to_s,
      "media_bytes" => media_bytes.to_i,
      "duplicate_story_storage_prevented" => ActiveModel::Type::Boolean.new.cast(existing_story_record),
      "ingested_at" => Time.current.iso8601
    )
  end

  def extract_duration_seconds(story:, current:)
    values = [
      story[:duration_seconds],
      story[:duration],
      story[:video_duration],
      current
    ]
    out = values.compact.map(&:to_f).find(&:positive?)
    out&.round(2)
  end

  def attach_media!(record:, bytes:, content_type:, filename:)
    return if record.media.attached?

    name = filename.to_s.presence || "story_#{record.story_id.parameterize}.bin"
    record.media.attach(io: StringIO.new(bytes), filename: name, content_type: content_type.to_s.presence || "application/octet-stream")
  rescue StandardError
    nil
  end

  def enqueue_processing!(record:, force_reprocess:)
    return unless @enqueue_processing
    return if record.processing_status == "processing"
    return if record.processed? && !force_reprocess

    StoryProcessingJob.perform_later(instagram_story_id: record.id, force: force_reprocess)
  end
end
