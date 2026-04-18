class AddPageSignalsToInstagramProfiles < ActiveRecord::Migration[8.1]
  # Persist the page/verification signals that were previously only
  # evaluated transiently inside Instagram::ProfileScanPolicy. The
  # engagement candidate filter (Phase 11) uses these at runtime to
  # decide whether to queue a story auto-reply / feed comment for a
  # given profile, so they need to be stable across scans.
  def change
    add_column :instagram_profiles, :is_business, :boolean, default: false, null: false
    add_column :instagram_profiles, :is_verified, :boolean, default: false, null: false
    add_column :instagram_profiles, :is_private, :boolean, default: false, null: false

    add_index :instagram_profiles, [:instagram_account_id, :is_business], name: "idx_instagram_profiles_account_is_business"
    add_index :instagram_profiles, [:instagram_account_id, :is_verified], name: "idx_instagram_profiles_account_is_verified"
  end
end
