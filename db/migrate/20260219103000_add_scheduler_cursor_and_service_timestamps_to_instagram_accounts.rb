class AddSchedulerCursorAndServiceTimestampsToInstagramAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :instagram_accounts, bulk: true do |t|
      t.bigint :continuous_processing_profile_scan_cursor_id
      t.bigint :continuous_processing_profile_refresh_cursor_id
      t.datetime :continuous_processing_last_story_sync_enqueued_at
      t.datetime :continuous_processing_last_feed_sync_enqueued_at
      t.datetime :continuous_processing_last_profile_scan_enqueued_at
      t.datetime :continuous_processing_last_profile_refresh_enqueued_at
    end
  end
end
