# frozen_string_literal: true

# Extends ai_provider_settings so a single provider (nvidia) can hold
# multiple role-specific rows (text_fast, text_quality, vision_primary,
# vision_fallback, embedding), each with its own model / api_key / base_url.
#
# Existing rows (provider=local) have role = NULL and keep working.
class ExtendAiProviderSettingsForNvidia < ActiveRecord::Migration[8.0]
  def up
    change_table :ai_provider_settings, bulk: true do |t|
      t.string :role
      t.string :model
      t.string :base_url
      t.integer :request_timeout_seconds
      t.integer :rate_limit_rpm
      t.string :display_label
    end

    remove_index :ai_provider_settings,
                 name: "index_ai_provider_settings_on_provider",
                 if_exists: true

    # Postgres treats NULL as distinct in unique indexes, so the legacy
    # `provider=local, role=NULL` row remains unique while we add one
    # row per (nvidia, role).
    add_index :ai_provider_settings,
              [:provider, :role],
              unique: true,
              name: "index_ai_provider_settings_on_provider_and_role"

    add_index :ai_provider_settings, :role
  end

  def down
    remove_index :ai_provider_settings,
                 name: "index_ai_provider_settings_on_role",
                 if_exists: true
    remove_index :ai_provider_settings,
                 name: "index_ai_provider_settings_on_provider_and_role",
                 if_exists: true

    add_index :ai_provider_settings, :provider,
              unique: true,
              name: "index_ai_provider_settings_on_provider"

    change_table :ai_provider_settings, bulk: true do |t|
      t.remove :role, :model, :base_url,
               :request_timeout_seconds, :rate_limit_rpm, :display_label
    end
  end
end
