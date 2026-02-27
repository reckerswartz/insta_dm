Rails.application.config.to_prepare do
  next unless defined?(ActiveStorage::Attachment)

  ActiveStorage::Attachment.include(ActiveStorageIngestionTracking) unless ActiveStorage::Attachment < ActiveStorageIngestionTracking

  unless ActiveStorage::Attachment.reflect_on_association(:active_storage_ingestion)
    ActiveStorage::Attachment.has_one(
      :active_storage_ingestion,
      class_name: "ActiveStorageIngestion",
      foreign_key: :active_storage_attachment_id,
      inverse_of: :attachment,
      dependent: :destroy
    )
  end
end
