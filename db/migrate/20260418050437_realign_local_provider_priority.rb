# frozen_string_literal: true

# Phase 4.2 bumped the LocalProvider's default priority from 1 to 20 so
# Ai::Runner tries NVIDIA before the legacy local stack. find_or_create_by!
# in Ai::ProviderRegistry only applies the new default to NEW rows, so
# existing production DBs still carry local.priority = 1 and would have
# Ai::Runner call LocalProvider first (which then fails because the
# Python microservice was deleted in Phase 5).
#
# This data migration realigns the legacy row. Idempotent: only rows
# currently at priority 1 are updated; operators who have already set a
# custom priority are left alone.
class RealignLocalProviderPriority < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      UPDATE ai_provider_settings
      SET priority = 20
      WHERE provider = 'local'
        AND priority = 1;
    SQL
  end

  def down
    execute(<<~SQL)
      UPDATE ai_provider_settings
      SET priority = 1
      WHERE provider = 'local'
        AND priority = 20;
    SQL
  end
end
