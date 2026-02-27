# frozen_string_literal: true

class StoryReplyTextSanitizer
  WRAPPING_QUOTE_PAIRS = [
    ['"', '"'],
    ["'", "'"],
    ["“", "”"],
    ["‘", "’"]
  ].freeze

  EDGE_QUOTES_REGEX = /\A["'“”‘’]+|["'“”‘’]+\z/.freeze
  TRAILING_PUNCTUATION_REGEX = /(?:[,\u060C\uFF0C;:]+\s*)+\z/.freeze

  class << self
    def call(text)
      value = text.to_s.strip
      return "" if value.blank?

      value = strip_wrapping_quotes(value)
      value = value.gsub(EDGE_QUOTES_REGEX, "").strip
      value = value.gsub(TRAILING_PUNCTUATION_REGEX, "").strip
      value.gsub(EDGE_QUOTES_REGEX, "").strip
    rescue StandardError
      text.to_s.strip
    end

    private

    def strip_wrapping_quotes(value)
      current = value

      loop do
        updated = strip_single_quote_layer(current)
        break current if updated == current

        current = updated
      end
    end

    def strip_single_quote_layer(value)
      WRAPPING_QUOTE_PAIRS.each do |opening, closing|
        next unless value.length > (opening.length + closing.length)
        next unless value.start_with?(opening) && value.end_with?(closing)

        return value[opening.length...-closing.length].to_s.strip
      end

      value
    end
  end
end
