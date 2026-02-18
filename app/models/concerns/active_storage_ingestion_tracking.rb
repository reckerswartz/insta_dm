module ActiveStorageIngestionTracking
  extend ActiveSupport::Concern

  included do
    after_create_commit :capture_storage_ingestion_row
  end

  private

  def capture_storage_ingestion_row
    ActiveStorageIngestion.record_from_attachment!(attachment: self)
  end
end
