# frozen_string_literal: true

class AddPipelinePendingFieldsToPostsAndEvents < ActiveRecord::Migration[8.0]
  def change
    change_table :instagram_profile_posts, bulk: true do |t|
      t.string :ai_pipeline_run_id
      t.string :ai_blocking_step
      t.string :ai_pending_reason_code
      t.datetime :ai_pending_since_at
      t.datetime :ai_next_retry_at
      t.datetime :ai_estimated_ready_at
    end

    add_index :instagram_profile_posts, :ai_pipeline_run_id
    add_index :instagram_profile_posts, :ai_blocking_step
    add_index :instagram_profile_posts, :ai_pending_reason_code
    add_index :instagram_profile_posts, :ai_estimated_ready_at

    change_table :instagram_profile_events, bulk: true do |t|
      t.string :llm_pipeline_run_id
      t.string :llm_blocking_step
      t.string :llm_pending_reason_code
      t.datetime :llm_estimated_ready_at
    end

    add_index :instagram_profile_events, :llm_pipeline_run_id
    add_index :instagram_profile_events, :llm_blocking_step
    add_index :instagram_profile_events, :llm_pending_reason_code
    add_index :instagram_profile_events, :llm_estimated_ready_at
  end
end
