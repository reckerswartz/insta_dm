Rails.application.config.to_prepare do
  next unless defined?(ActiveStorage::Attachment)

  ActiveStorage::Attachment.include(ActiveStorageIngestionTracking) unless ActiveStorage::Attachment < ActiveStorageIngestionTracking
end
