class StoryContentUnderstandingService
  def build(media_type:, detections:, transcript_text: nil)
    rows = Array(detections)
    faces = rows.sum { |row| Array(row[:faces]).length }
    ocr_chunks = rows.map { |row| row[:ocr_text].to_s.strip }.reject(&:blank?)
    ocr_text = ocr_chunks.uniq.join("\n").strip.presence

    locations = rows.flat_map { |row| Array(row[:location_tags]) }.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    objects = rows.flat_map { |row| Array(row[:content_signals]) }.map(&:to_s).map(&:strip).reject(&:blank?)
    mentions = rows.flat_map { |row| Array(row[:mentions]) }.map(&:to_s).map(&:downcase).uniq
    hashtags = rows.flat_map { |row| Array(row[:hashtags]) }.map(&:to_s).map(&:downcase).uniq

    combined_text = [ ocr_text, transcript_text.to_s ].compact.join("\n")
    sentiment = infer_sentiment(combined_text)
    topics = infer_topics(objects: objects, hashtags: hashtags, transcript: transcript_text, ocr_text: ocr_text)

    {
      objects: objects.first(60),
      faces: faces,
      locations: locations.first(30),
      ocr_text: ocr_text,
      transcript: transcript_text.to_s.presence,
      sentiment: sentiment,
      topics: topics.first(30),
      mentions: mentions.first(40),
      hashtags: hashtags.first(40),
      media_type: media_type.to_s
    }
  end

  private

  POSITIVE_TERMS = %w[happy great love awesome excited win winning strong proud blessed amazing].freeze
  NEGATIVE_TERMS = %w[sad angry upset bad pain tired depressed sick fail failing stressed].freeze
  STOPWORDS = %w[the a an and or to of in on at for with is are this that from your my our they].freeze

  def infer_sentiment(text)
    tokens = tokenize(text)
    return "neutral" if tokens.empty?

    positive = tokens.count { |token| POSITIVE_TERMS.include?(token) }
    negative = tokens.count { |token| NEGATIVE_TERMS.include?(token) }
    return "positive" if positive > negative
    return "negative" if negative > positive

    "neutral"
  end

  def infer_topics(objects:, hashtags:, transcript:, ocr_text:)
    from_labels = objects.map(&:downcase)
    from_hashtags = hashtags.map { |tag| tag.to_s.sub(/^#/, "") }.reject(&:blank?)
    from_text = tokenize([ transcript, ocr_text ].join(" ")).reject { |token| STOPWORDS.include?(token) }
    (from_labels + from_hashtags + from_text).reject(&:blank?).uniq
  end

  def tokenize(text)
    text.to_s.downcase.scan(/[a-z0-9_]+/)
  end
end
