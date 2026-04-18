# frozen_string_literal: true

# Phase 9 of the NVIDIA migration removes Ai::Providers::LocalProvider.
# Drop the legacy ai_provider_settings row for it so the new provider
# model validation (inclusion: %w[nvidia]) doesn't trip on existing rows.
# Idempotent: no-ops if the row has already been removed.
class RemoveLocalProviderSetting < ActiveRecord::Migration[8.0]
  def up
    execute("DELETE FROM ai_provider_settings WHERE provider = 'local'")
  end

  def down
    # Best-effort reinsert so a rollback doesn't leave the registry
    # believing the local provider is still configured. Phase 4.2's
    # priority of 20 is the value the pre-Phase-9 registry used; enabled
    # is kept false so ops consciously decide to switch back.
    execute(<<~SQL)
      INSERT INTO ai_provider_settings (provider, enabled, priority, role, created_at, updated_at)
      VALUES ('local', false, 20, NULL, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL
  end
end
