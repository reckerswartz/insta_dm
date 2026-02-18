class ActiveStorageIngestion < ApplicationRecord
  belongs_to :attachment, class_name: "ActiveStorage::Attachment", foreign_key: :active_storage_attachment_id
  belongs_to :blob, class_name: "ActiveStorage::Blob", foreign_key: :active_storage_blob_id
  belongs_to :instagram_account, optional: true
  belongs_to :instagram_profile, optional: true

  validates :active_storage_attachment_id, uniqueness: true
  validates :attachment_name, :blob_filename, :blob_byte_size, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  after_commit :broadcast_live_updates

  def self.record_from_attachment!(attachment:)
    return if exists?(active_storage_attachment_id: attachment.id)

    blob = attachment.blob
    context = extract_record_context(record: attachment.record)
    current_context = Current.job_context

    create!(
      active_storage_attachment_id: attachment.id,
      active_storage_blob_id: blob.id,
      attachment_name: attachment.name.to_s,
      record_type: attachment.record_type.to_s,
      record_id: attachment.record_id,
      blob_filename: blob.filename.to_s,
      blob_content_type: blob.content_type.to_s.presence,
      blob_byte_size: blob.byte_size.to_i,
      instagram_account_id: context[:instagram_account_id] || current_context[:instagram_account_id],
      instagram_profile_id: context[:instagram_profile_id] || current_context[:instagram_profile_id],
      created_by_job_class: current_context[:job_class],
      created_by_active_job_id: current_context[:active_job_id],
      created_by_provider_job_id: current_context[:provider_job_id],
      queue_name: current_context[:queue_name],
      metadata: {
        service_name: blob.service_name,
        checksum: blob.checksum,
        content_type: blob.content_type,
        blob_created_at: blob.created_at&.iso8601
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[storage.ingestion] capture failed: #{e.class}: #{e.message}")
    nil
  end

  def self.extract_record_context(record:)
    return {} unless record

    account_id =
      if record.respond_to?(:instagram_account_id)
        record.instagram_account_id
      elsif record.respond_to?(:instagram_account) && record.instagram_account.respond_to?(:id)
        record.instagram_account.id
      end

    profile_id =
      if record.respond_to?(:instagram_profile_id)
        record.instagram_profile_id
      elsif record.respond_to?(:instagram_profile) && record.instagram_profile.respond_to?(:id)
        record.instagram_profile.id
      elsif record.is_a?(InstagramProfile)
        record.id
      end

    { instagram_account_id: account_id, instagram_profile_id: profile_id }
  rescue StandardError
    {}
  end

  private

  def broadcast_live_updates
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "storage_ingestions_changed",
      account_id: instagram_account_id,
      payload: { ingestion_id: id },
      throttle_key: "storage_ingestions_changed"
    )
  end
end
