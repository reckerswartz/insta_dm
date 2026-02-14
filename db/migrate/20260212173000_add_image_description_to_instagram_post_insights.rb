class AddImageDescriptionToInstagramPostInsights < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_post_insights, :image_description, :text
  end
end
