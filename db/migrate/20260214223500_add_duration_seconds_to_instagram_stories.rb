class AddDurationSecondsToInstagramStories < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_stories, :duration_seconds, :float
  end
end
