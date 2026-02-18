class AddLlmCommentLifecycleAndIndexes < ActiveRecord::Migration[8.1]
  def change
    change_table :instagram_profile_events, bulk: true do |t|
      t.string :llm_comment_status, null: false, default: "not_requested"
      t.integer :llm_comment_attempts, null: false, default: 0
      t.text :llm_comment_last_error
      t.string :llm_comment_job_id
      t.float :llm_comment_relevance_score
    end

    add_index :instagram_profile_events,
      [:llm_comment_status, :detected_at],
      name: "idx_profile_events_llm_status_detected"

    add_index :instagram_profile_events,
      :llm_comment_job_id,
      name: "idx_profile_events_llm_comment_job_id"

    add_index :instagram_profile_events,
      [:instagram_profile_id, :kind, :occurred_at],
      name: "idx_profile_events_profile_kind_occurred"

    add_index :instagram_profiles,
      [:instagram_account_id, :ai_last_analyzed_at],
      name: "idx_instagram_profiles_account_last_analyzed"
  end
end
