class EnablePgvectorAndAddStoryEmbeddingVectors < ActiveRecord::Migration[8.1]
  def up
    return unless postgres?
    return unless pgvector_available?

    enable_extension "vector" unless extension_enabled?("vector")

    unless column_exists?(:instagram_story_people, :canonical_embedding_vector)
      add_column :instagram_story_people, :canonical_embedding_vector, :vector, limit: 512
    end

    unless column_exists?(:instagram_story_faces, :embedding_vector)
      add_column :instagram_story_faces, :embedding_vector, :vector, limit: 512
    end

    add_pgvector_indexes
  end

  def down
    return unless postgres?
    return unless extension_enabled?("vector")

    execute "DROP INDEX IF EXISTS index_story_people_on_canonical_embedding_vector_ivfflat"
    execute "DROP INDEX IF EXISTS index_story_faces_on_embedding_vector_ivfflat"

    remove_column :instagram_story_people, :canonical_embedding_vector if column_exists?(:instagram_story_people, :canonical_embedding_vector)
    remove_column :instagram_story_faces, :embedding_vector if column_exists?(:instagram_story_faces, :embedding_vector)
  end

  private

  def postgres?
    connection.adapter_name.to_s.downcase.include?("postgresql")
  end

  def add_pgvector_indexes
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_story_people_on_canonical_embedding_vector_ivfflat
      ON instagram_story_people USING ivfflat (canonical_embedding_vector vector_cosine_ops)
      WITH (lists = 100);
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_story_faces_on_embedding_vector_ivfflat
      ON instagram_story_faces USING ivfflat (embedding_vector vector_cosine_ops)
      WITH (lists = 100);
    SQL
  end

  def pgvector_available?
    return true if extension_enabled?("vector")

    available = connection.select_values("SELECT name FROM pg_available_extensions WHERE name = 'vector'")
    return false if available.empty?

    true
  rescue StandardError
    false
  end
end
