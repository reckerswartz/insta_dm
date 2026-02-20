class ResponseGenerationService
  def initialize(personalization_engine: PersonalizationEngine.new, context_signal_scorer_builder: nil)
    @personalization_engine = personalization_engine
    @context_signal_scorer_builder = context_signal_scorer_builder
  end

  def generate(profile:, content_understanding:, max_suggestions: 5)
    persona = @personalization_engine.build(profile: profile)
    understanding = content_understanding.is_a?(Hash) ? content_understanding : {}
    topics = normalize_array(understanding[:topics] || understanding["topics"]).first(8)
    sentiment = (understanding[:sentiment] || understanding["sentiment"]).to_s
    scored_context = build_scored_context(profile: profile, topics: topics, content_understanding: understanding)
    engagement_memory = scored_context[:engagement_memory].is_a?(Hash) ? scored_context[:engagement_memory] : {}
    prioritized_signals = Array(scored_context[:prioritized_signals]).filter_map do |row|
      next unless row.is_a?(Hash)

      row[:value].to_s.presence || row["value"].to_s.presence
    end.first(8)
    candidate_topics = (topics + prioritized_signals + Array(persona[:interests])).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(10)
    relationship_familiarity = engagement_memory[:relationship_familiarity].to_s.presence || "neutral"

    suggestions = base_templates(
      tone: persona[:tone],
      sentiment: sentiment,
      relationship_familiarity: relationship_familiarity
    ).map.with_index do |template, idx|
      topic = candidate_topics[idx % candidate_topics.length] if candidate_topics.any?
      rendered = topic.present? ? template.gsub("{topic}", topic) : template.gsub(" {topic}", "")
      rendered.gsub("{signal}", prioritized_signals.first.to_s)
    end

    filtered = filter_with_engagement_memory(suggestions: suggestions, engagement_memory: engagement_memory)
    filtered.first(max_suggestions.to_i.clamp(1, 10))
  end

  private

  def build_scored_context(profile:, topics:, content_understanding:)
    scorer = if @context_signal_scorer_builder.respond_to?(:call)
      @context_signal_scorer_builder.call(profile: profile, channel: "story")
    else
      Ai::ContextSignalScorer.new(profile: profile, channel: "story")
    end

    scorer.build(
      current_topics: topics,
      image_description: content_understanding[:image_description].to_s.presence || content_understanding["image_description"].to_s,
      caption: [
        content_understanding[:ocr_text],
        content_understanding["ocr_text"],
        content_understanding[:transcript],
        content_understanding["transcript"]
      ].map(&:to_s).reject(&:blank?).join(" "),
      limit: 10
    )
  rescue StandardError
    {}
  end

  def base_templates(tone:, sentiment:, relationship_familiarity:)
    return empathetic_templates if tone == "empathetic" || sentiment == "negative"
    return familiar_templates if relationship_familiarity == "friendly"
    return optimistic_templates if tone == "optimistic" || sentiment == "positive"

    neutral_templates
  end

  def familiar_templates
    [
      "This feels very you lately, especially around {topic}.",
      "Another great {topic} moment from your feed.",
      "Love the consistency in your {topic} posts.",
      "This one fits your usual vibe around {topic}.",
      "Great update, the {topic} angle lands really well."
    ]
  end

  def optimistic_templates
    [
      "Love this energy around {topic}.",
      "This looks amazing, especially the {topic} moment.",
      "Big fan of this one, great vibe.",
      "This is strong content. Keep it coming.",
      "Great share, this feels really authentic."
    ]
  end

  def empathetic_templates
    [
      "Appreciate you sharing this.",
      "Sending support your way.",
      "This felt real and honest.",
      "Thanks for posting this perspective.",
      "Rooting for you."
    ]
  end

  def neutral_templates
    [
      "Nice story update.",
      "This was a good share.",
      "Loved the {topic} angle here.",
      "Clean and engaging post.",
      "Great context in this one."
    ]
  end

  def filter_with_engagement_memory(suggestions:, engagement_memory:)
    recent_openers = Array(engagement_memory[:recent_openers]).map(&:to_s)
    recent_comments = Array(engagement_memory[:recent_generated_comments]) + Array(engagement_memory[:recent_story_generated_comments])
    recent_comments = recent_comments.map { |value| normalize_sentence(value) }.reject(&:blank?)

    out = []
    Array(suggestions).each do |raw|
      sentence = normalize_sentence(raw)
      next if sentence.blank?
      next if recent_openers.include?(opening_signature(sentence))
      next if near_duplicate?(sentence, recent_comments)
      next if out.any? { |existing| opening_signature(existing) == opening_signature(sentence) }

      out << sentence
    end

    out = Array(suggestions).map { |value| normalize_sentence(value) }.reject(&:blank?).uniq if out.empty?
    out
  end

  def near_duplicate?(sentence, prior_rows)
    tokens = normalize_tokens(sentence)
    return false if tokens.empty?

    Array(prior_rows).any? do |prior|
      prior_tokens = normalize_tokens(prior)
      next false if prior_tokens.empty?

      overlap = (tokens & prior_tokens).size
      overlap.to_f / [tokens.size, prior_tokens.size].max >= 0.72
    end
  end

  def normalize_sentence(value)
    value.to_s.gsub(/\s+/, " ").strip
  end

  def opening_signature(sentence)
    normalize_tokens(sentence).first(3).join(" ")
  end

  def normalize_tokens(value)
    value.to_s.downcase.scan(/[a-z0-9]+/)
  end

  def normalize_array(value)
    Array(value).filter_map do |entry|
      token = entry.to_s.strip
      token.presence
    end
  end
end
