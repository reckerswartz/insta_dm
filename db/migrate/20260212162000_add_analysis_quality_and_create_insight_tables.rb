class AddAnalysisQualityAndCreateInsightTables < ActiveRecord::Migration[8.1]
  def change
    change_table :ai_analyses, bulk: true do |t|
      t.float :input_completeness_score
      t.float :confidence_score
      t.integer :evidence_count
      t.integer :signals_detected_count
      t.string :prompt_version
      t.string :schema_version
    end

    add_index :ai_analyses, :confidence_score
    add_index :ai_analyses, [ :purpose, :provider, :created_at ]

    create_table :instagram_profile_insights do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.references :ai_analysis, null: false, foreign_key: true

      t.text :summary
      t.string :primary_language
      t.json :secondary_languages
      t.string :tone
      t.string :formality
      t.string :emoji_usage
      t.string :slang_level
      t.string :engagement_style
      t.string :profile_type
      t.float :messageability_score
      t.datetime :last_refreshed_at, null: false
      t.json :raw_analysis

      t.timestamps
    end

    add_index :instagram_profile_insights, [ :instagram_profile_id, :created_at ]
    add_index :instagram_profile_insights, [ :instagram_account_id, :created_at ]

    create_table :instagram_profile_message_strategies do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.references :ai_analysis, null: false, foreign_key: true
      t.references :instagram_profile_insight, null: false, foreign_key: true

      t.json :opener_templates
      t.json :comment_templates
      t.json :dos
      t.json :donts
      t.string :cta_style
      t.json :best_topics
      t.json :avoid_topics

      t.timestamps
    end

    add_index :instagram_profile_message_strategies, [ :instagram_profile_id, :created_at ], name: "idx_profile_message_strategies_profile_created"

    create_table :instagram_profile_signal_evidences do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.references :ai_analysis, null: false, foreign_key: true
      t.references :instagram_profile_insight, null: false, foreign_key: true

      t.string :signal_type, null: false
      t.string :value
      t.float :confidence
      t.text :evidence_text
      t.string :source_type
      t.string :source_ref
      t.datetime :occurred_at

      t.timestamps
    end

    add_index :instagram_profile_signal_evidences, [ :instagram_profile_id, :signal_type ], name: "idx_profile_signal_evidence_profile_signal"
    add_index :instagram_profile_signal_evidences, [ :source_type, :source_ref ]

    create_table :instagram_post_insights do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_post, null: false, foreign_key: true
      t.references :ai_analysis, null: false, foreign_key: true

      t.boolean :relevant
      t.string :author_type
      t.string :sentiment
      t.json :topics
      t.json :suggested_actions
      t.json :comment_suggestions
      t.float :confidence
      t.text :evidence
      t.float :engagement_score
      t.string :recommended_next_action
      t.json :raw_analysis

      t.timestamps
    end

    add_index :instagram_post_insights, [ :instagram_post_id, :created_at ]
    add_index :instagram_post_insights, [ :instagram_account_id, :created_at ]

    create_table :instagram_post_entities do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_post, null: false, foreign_key: true
      t.references :instagram_post_insight, null: false, foreign_key: true

      t.string :entity_type, null: false
      t.string :value, null: false
      t.float :confidence
      t.text :evidence_text
      t.string :source_type
      t.string :source_ref

      t.timestamps
    end

    add_index :instagram_post_entities, [ :instagram_post_id, :entity_type ], name: "idx_post_entities_post_type"
  end
end
