# frozen_string_literal: true

module Ai
  class CommentToneProfile
    VALID_CHANNELS = %w[post story dm].freeze

    CHANNEL_PROFILES = {
      "post" => {
        label: "post_comment",
        guidance: "Casual, socially native, and warm: like a real friend replying on Instagram.",
        writing_rules: [
          "Use natural conversational phrasing and keep it context-aware.",
          "Use light emoji sparingly when it adds tone (not every line).",
          "Avoid robotic visual narration or camera-analysis wording."
        ]
      },
      "story" => {
        label: "story_reply",
        guidance: "Quick, chatty, and relatable with light Gen Z energy.",
        writing_rules: [
          "Prioritize short human reactions over formal commentary.",
          "Add a personal touch or light question when naturally grounded.",
          "Keep it socially safe and avoid overfamiliar assumptions."
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
