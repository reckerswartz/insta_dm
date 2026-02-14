class ResponseGenerationService
  def initialize(personalization_engine: PersonalizationEngine.new)
    @personalization_engine = personalization_engine
  end

  def generate(profile:, content_understanding:, max_suggestions: 5)
    persona = @personalization_engine.build(profile: profile)
    topics = Array(content_understanding[:topics]).first(5)
    sentiment = content_understanding[:sentiment].to_s

    suggestions = base_templates(tone: persona[:tone], sentiment: sentiment).map do |template|
      topic = topics.first
      topic.present? ? template.gsub("{topic}", topic) : template.gsub(" {topic}", "")
    end

    suggestions.map!(&:strip)
    suggestions.uniq.first(max_suggestions.to_i.clamp(1, 10))
  end

  private

  def base_templates(tone:, sentiment:)
    return empathetic_templates if tone == "empathetic" || sentiment == "negative"
    return optimistic_templates if tone == "optimistic" || sentiment == "positive"

    neutral_templates
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
end
