class CreateActiveStorageIngestions < ActiveRecord::Migration[8.1]
  def change
    create_table :active_storage_ingestions do |t|
      t.bigint :active_storage_attachment_id, null: false
      t.bigint :active_storage_blob_id, null: false
      t.string :attachment_name, null: false
      t.string :record_type
      t.bigint :record_id
      t.string :blob_filename, null: false
      t.string :blob_content_type
      t.bigint :blob_byte_size, null: false
      t.bigint :instagram_account_id
      t.bigint :instagram_profile_id
      t.string :created_by_job_class
      t.string :created_by_active_job_id
      t.string :created_by_provider_job_id
      t.string :queue_name
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :active_storage_ingestions, :active_storage_attachment_id, unique: true, name: "idx_storage_ingestions_attachment_unique"
    add_index :active_storage_ingestions, %i[record_type record_id], name: "idx_storage_ingestions_record"
    add_index :active_storage_ingestions, :created_at
    add_index :active_storage_ingestions, :created_by_job_class
    add_index :active_storage_ingestions, :created_by_active_job_id
    add_index :active_storage_ingestions, :instagram_account_id
    add_index :active_storage_ingestions, :instagram_profile_id

    add_foreign_key :active_storage_ingestions, :active_storage_attachments, column: :active_storage_attachment_id
    add_foreign_key :active_storage_ingestions, :active_storage_blobs, column: :active_storage_blob_id
    add_foreign_key :active_storage_ingestions, :instagram_accounts
    add_foreign_key :active_storage_ingestions, :instagram_profiles
  end
end
