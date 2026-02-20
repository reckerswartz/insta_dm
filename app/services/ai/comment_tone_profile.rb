# frozen_string_literal: true

module Ai
  class CommentToneProfile
    VALID_CHANNELS = %w[post story dm].freeze

    CHANNEL_PROFILES = {
      "post" => {
        label: "post_comment",
        guidance: "Slightly richer and contextual while remaining concise.",
        writing_rules: [
          "Reference visual details or caption context when available.",
          "Keep tone friendly and public-safe.",
          "Avoid overreactive slang unless strongly grounded in profile voice."
        ]
      },
      "story" => {
        label: "story_reply",
        guidance: "Short, reactive, and lightweight for fast story engagement.",
        writing_rules: [
          "Prioritize quick reactions over long statements.",
          "Keep suggestions punchy and conversational.",
          "Avoid deep assumptions about background details."
        ]
      },
      "dm" => {
        label: "dm_draft",
        guidance: "Natural conversational draft for human review before send.",
        writing_rules: [
          "Use warm, respectful wording.",
          "Prefer open-ended, low-pressure phrasing.",
          "Avoid pushy asks, manipulative urgency, or overfamiliar claims."
        ]
      }
    }.freeze

    class << self
      def normalize(channel)
        value = channel.to_s.strip.downcase
        return value if VALID_CHANNELS.include?(value)

        "post"
      end

      def for(channel)
        CHANNEL_PROFILES.fetch(normalize(channel))
      end
    end
  end
end
