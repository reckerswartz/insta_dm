class BackfillAiAnalysesFromProfileAnalyses < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class MigrationProfile < ApplicationRecord
    self.table_name = "instagram_profiles"
  end

  class MigrationProfileAnalysis < ApplicationRecord
    self.table_name = "instagram_profile_analyses"
  end

  class MigrationAiAnalysis < ApplicationRecord
    self.table_name = "ai_analyses"

    encrypts :prompt
    encrypts :response_text
  end

  def up
    return unless table_exists?(:ai_analyses) && table_exists?(:instagram_profile_analyses)

    say_with_time "Backfilling ai_analyses from instagram_profile_analyses" do
      MigrationProfileAnalysis.find_in_batches(batch_size: 200) do |batch|
        batch.each do |legacy|
          profile = MigrationProfile.find_by(id: legacy.instagram_profile_id)
          next unless profile

          MigrationAiAnalysis.create!(
            instagram_account_id: profile.instagram_account_id,
            analyzable_type: "InstagramProfile",
            analyzable_id: legacy.instagram_profile_id,
            purpose: "profile",
            provider: legacy.provider.to_s.presence || "xai",
            model: legacy.model,
            status: legacy.status.to_s.presence || "succeeded",
            started_at: legacy.started_at,
            finished_at: legacy.finished_at,
            prompt: legacy.prompt,
            response_text: legacy.response_text,
            analysis: legacy.analysis,
            metadata: legacy.metadata,
            error_message: legacy.error_message,
            created_at: legacy.created_at,
            updated_at: legacy.updated_at
          )
        end
      end
    end
  end

  def down
    # no-op: backfill migration
  end
end
