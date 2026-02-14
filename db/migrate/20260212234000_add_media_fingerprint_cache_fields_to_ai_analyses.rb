class AddMediaFingerprintCacheFieldsToAiAnalyses < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_analyses, :media_fingerprint, :string
    add_column :ai_analyses, :cache_hit, :boolean, null: false, default: false
    add_reference :ai_analyses, :cached_from_ai_analysis, foreign_key: { to_table: :ai_analyses }

    add_index :ai_analyses, [ :purpose, :media_fingerprint, :status ], name: "idx_ai_analyses_reuse_lookup"
  end
end
