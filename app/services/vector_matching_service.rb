class VectorMatchingService
  DEFAULT_THRESHOLD = 0.85

  def initialize(threshold: nil)
    @threshold = threshold.to_f.positive? ? threshold.to_f : DEFAULT_THRESHOLD
  end

  def match_or_create!(account:, profile:, embedding:, occurred_at: Time.current)
    vector = normalize(embedding)
    raise ArgumentError, "embedding vector is required" if vector.empty?

    best = best_match(profile: profile, vector: vector)
    if best && best[:similarity] >= @threshold
      person = best[:person]
      upsert_person_embedding!(person: person, vector: vector, occurred_at: occurred_at)
      role = person.role == "primary_user" ? "primary_user" : "secondary_person"
      return { person: person, matched: true, similarity: best[:similarity], role: role }
    end

    attrs = {
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      first_seen_at: occurred_at,
      last_seen_at: occurred_at,
      appearance_count: 1,
      canonical_embedding: vector,
      metadata: { source: "auto_cluster" }
    }
    attrs[:canonical_embedding_vector] = vector if pgvector_column_available?
    person = InstagramStoryPerson.create!(attrs)

    {
      person: person,
      matched: false,
      similarity: best&.dig(:similarity),
      role: person.role
    }
  end

  def upsert_primary_person!(account:, profile:, embedding:, occurred_at: Time.current, label: nil)
    vector = normalize(embedding)
    raise ArgumentError, "embedding vector is required" if vector.empty?

    person = InstagramStoryPerson.find_or_initialize_by(
      instagram_account: account,
      instagram_profile: profile,
      role: "primary_user"
    )
    person.label = label if label.present?
    person.first_seen_at ||= occurred_at
    person.last_seen_at = [ person.last_seen_at, occurred_at ].compact.max
    person.appearance_count = [ person.appearance_count.to_i, 1 ].max
    person.canonical_embedding = vector
    person.canonical_embedding_vector = vector if person.respond_to?(:canonical_embedding_vector=)
    person.metadata = (person.metadata.is_a?(Hash) ? person.metadata : {}).merge("source" => "primary_seed")
    person.save!
    person
  end

  private

  def best_match(profile:, vector:)
    if pgvector_enabled?
      vector_sql = vector_literal(vector)
      query = profile.instagram_story_people.where.not(canonical_embedding_vector: nil)
      return nil unless query.exists?

      person = query
        .select(Arel.sql("instagram_story_people.*, (1 - (canonical_embedding_vector <=> '#{vector_sql}'::vector)) AS similarity_score"))
        .order(Arel.sql("canonical_embedding_vector <=> '#{vector_sql}'::vector"))
        .limit(1)
        .first
      return nil unless person

      return { person: person, similarity: person.attributes["similarity_score"].to_f }
    end

    candidates = profile.instagram_story_people.where.not(canonical_embedding: nil).to_a
    return nil if candidates.empty?

    candidates.map do |person|
      other = normalize(person.canonical_embedding)
      next nil if other.length != vector.length

      { person: person, similarity: cosine_similarity(vector, other) }
    end.compact.max_by { |item| item[:similarity] }
  end

  def upsert_person_embedding!(person:, vector:, occurred_at:)
    current_count = person.appearance_count.to_i
    current = normalize(person.canonical_embedding)

    updated_vector = if current.length == vector.length && current_count.positive?
      merged = current.each_with_index.map do |value, idx|
        ((value * current_count) + vector[idx]) / (current_count + 1)
      end
      normalize(merged)
    else
      vector
    end

    attrs = {
      canonical_embedding: updated_vector,
      appearance_count: current_count + 1,
      first_seen_at: person.first_seen_at || occurred_at,
      last_seen_at: [ person.last_seen_at, occurred_at ].compact.max
    }
    attrs[:canonical_embedding_vector] = updated_vector if person.respond_to?(:canonical_embedding_vector=)
    person.update!(attrs)
  end

  def cosine_similarity(a, b)
    dot = 0.0
    mag_a = 0.0
    mag_b = 0.0

    a.each_with_index do |left, idx|
      right = b[idx].to_f
      dot += left * right
      mag_a += left * left
      mag_b += right * right
    end

    denom = Math.sqrt(mag_a) * Math.sqrt(mag_b)
    return 0.0 if denom <= 0.0

    dot / denom
  end

  def normalize(values)
    vector = Array(values).map(&:to_f)
    return [] if vector.empty?

    norm = Math.sqrt(vector.sum { |value| value * value })
    return [] if norm <= 0.0

    vector.map { |value| value / norm }
  end

  def pgvector_enabled?
    return false unless ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?("postgresql")
    pgvector_column_available?
  rescue StandardError
    false
  end

  def pgvector_column_available?
    InstagramStoryPerson.column_names.include?("canonical_embedding_vector")
  end

  def vector_literal(vector)
    "[" + vector.map { |value| format("%.8f", value.to_f) }.join(",") + "]"
  end
end
