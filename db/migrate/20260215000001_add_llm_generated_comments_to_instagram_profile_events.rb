class AddLlmGeneratedCommentsToInstagramProfileEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_profile_events, :llm_generated_comment, :text
    add_column :instagram_profile_events, :llm_comment_generated_at, :datetime
    add_column :instagram_profile_events, :llm_comment_model, :string
    add_column :instagram_profile_events, :llm_comment_provider, :string
    add_column :instagram_profile_events, :llm_comment_metadata, :json, default: {}
    
    # Add index for performance
    add_index :instagram_profile_events, :llm_comment_generated_at
    add_index :instagram_profile_events, [:llm_comment_provider, :llm_comment_generated_at]
  end
end
