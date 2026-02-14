class PersonalizationEngine
  DEFAULT_PROFILE = {
    tone: "friendly",
    interests: [],
    emoji_style: "moderate",
    engagement_style: "supportive"
  }.freeze

  def build(profile:)
    behavior = profile.instagram_profile_behavior_profile
    summary = behavior&.behavioral_summary.is_a?(Hash) ? behavior.behavioral_summary : {}

    interests = summary.fetch("content_categories", {}).to_h.keys.first(8)
    {
      tone: infer_tone(summary),
      interests: interests,
      emoji_style: infer_emoji_style(summary),
      engagement_style: infer_engagement_style(summary)
    }
  rescue StandardError
    DEFAULT_PROFILE
  end

  private

  def infer_tone(summary)
    sentiment = summary.fetch("sentiment_trend", {}).to_h.max_by { |_key, value| value.to_i }&.first.to_s
    return "optimistic" if sentiment == "positive"
    return "calm" if sentiment == "neutral"
    return "empathetic" if sentiment == "negative"

    "friendly"
  end

  def infer_emoji_style(summary)
    tag_count = summary.fetch("top_hashtags", {}).to_h.values.sum(&:to_i)
    return "light" if tag_count < 5
    return "moderate" if tag_count < 25

    "expressive"
  end

  def infer_engagement_style(summary)
    recurring = summary.fetch("frequent_secondary_persons", []).size
    recurring >= 3 ? "community" : "supportive"
  end
end
