class CreateInstagramPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_posts do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, foreign_key: true

      t.string :shortcode, null: false
      t.string :post_kind, null: false, default: "post" # post|reel|unknown

      t.string :author_username
      t.string :author_ig_user_id

      t.text :caption
      t.datetime :taken_at
      t.datetime :detected_at, null: false

      t.string :status, null: false, default: "pending" # pending|analyzed|ignored
      t.json :analysis
      t.datetime :analyzed_at
      t.string :ai_provider
      t.string :ai_model

      t.string :media_url
      t.datetime :media_downloaded_at
      t.datetime :purge_at

      t.json :metadata

      t.timestamps
    end

    add_index :instagram_posts, [ :instagram_account_id, :shortcode ], unique: true
    add_index :instagram_posts, :detected_at
    add_index :instagram_posts, :status
    add_index :instagram_posts, :purge_at
  end
end

