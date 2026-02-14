class CreateProfileTagsAndTaggings < ActiveRecord::Migration[8.1]
  def change
    create_table :profile_tags do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :profile_tags, :name, unique: true

    create_table :instagram_profile_taggings do |t|
      t.references :instagram_profile, null: false, foreign_key: true
      t.references :profile_tag, null: false, foreign_key: true
      t.timestamps
    end
    add_index :instagram_profile_taggings, [ :instagram_profile_id, :profile_tag_id ], unique: true, name: "idx_profile_tagging_unique"
  end
end

