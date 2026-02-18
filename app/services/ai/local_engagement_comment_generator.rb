require "json"

module Ai
  class LocalEngagementCommentGenerator
    DEFAULT_MODEL = "mistral:7b".freeze
    MIN_SUGGESTIONS = 3
    MAX_SUGGESTIONS = 8

    BLOCKED_TERMS = %w[].freeze

    def initialize(ollama_client:, model: nil)
      @ollama_client = ollama_client
      @model = model.to_s.presence || DEFAULT_MODEL
    end

    def generate!(post_payload:, image_description:, topics:, author_type:, historical_comments: [], historical_context: nil)
      prompt = build_prompt(
        post_payload: post_payload,
        image_description: image_description,
        topics: topics,
        author_type: author_type,
        historical_comments: historical_comments,
        historical_context: historical_context
      )

      resp = @ollama_client.generate(
        model: @model,
        prompt: prompt,
        temperature: 0.9,
        max_tokens: 1200
      )

      # Parse JSON response from LLM
      parsed = JSON.parse(resp["response"]) rescue nil
      suggestions = Array(parsed&.dig("comment_suggestions")).map { |v| normalize_comment(v) }.compact.uniq
      suggestions = filter_safe_comments(suggestions)

      if suggestions.size < MIN_SUGGESTIONS
        fallback = fallback_comments(image_description: image_description, topics: topics).first(MAX_SUGGESTIONS)
        return {
          model: @model,
          prompt: prompt,
          raw: resp,
          source: "fallback",
          status: "fallback_used",
          fallback_used: true,
          error_message: "Generated suggestions were insufficient (#{suggestions.size}/#{MIN_SUGGESTIONS})",
          comment_suggestions: fallback
        }
      end

      {
        model: @model,
        prompt: prompt,
        raw: resp,
        source: "ollama",
        status: "ok",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: suggestions.first(MAX_SUGGESTIONS)
      }
    rescue StandardError => e
      {
        model: @model,
        prompt: prompt,
        raw: {},
        source: "fallback",
        status: "error_fallback",
        fallback_used: true,
        error_message: e.message.to_s,
        comment_suggestions: fallback_comments(image_description: image_description, topics: topics).first(MAX_SUGGESTIONS)
      }
    end

    private

    def build_prompt(post_payload:, image_description:, topics:, author_type:, historical_comments:, historical_context:)
      <<~PROMPT
        You are an Instagram engagement assistant.
        Generate short, natural comments for a single post/story.

        Style requirements:
        - modern, friendly, playful, Gen Z-adjacent tone
        - light slang + occasional emojis
        - comments should feel human and contextual to the post
        - avoid repetitive openers

        Safety and boundaries:
        - do NOT use explicit sexual language or adult content
        - mild flirty energy is acceptable only if respectful and non-explicit
        - no harassment, no insults, no coercive/manipulative lines
        - do not infer sensitive traits (race, religion, health, sexuality)

        Output STRICT JSON only:
        {
          "comment_suggestions": ["...", "...", "...", "...", "...", "...", "...", "..."]
        }

        Generate exactly 8 suggestions, each <= 140 characters.
        Keep at least 3 suggestions neutral-safe for public comments.
        Avoid repeating phrases from previous comments for the same profile.

        CONTEXT_JSON:
        #{JSON.pretty_generate({
          author_type: author_type,
          image_description: image_description,
          topics: Array(topics).first(12),
          historical_comments: Array(historical_comments).first(12),
          historical_context: historical_context.to_s,
          post: post_payload[:post],
          author_profile: post_payload[:author_profile],
          rules: post_payload[:rules]
        })}
      PROMPT
    end

    def filter_safe_comments(comments)
      filtered = Array(comments)
      return filtered if BLOCKED_TERMS.empty?

      filtered.reject do |comment|
        lc = comment.to_s.downcase
        BLOCKED_TERMS.any? { |term| lc.include?(term) }
      end
    end

    def normalize_comment(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return nil if text.blank?

      text.byteslice(0, 140)
    end

    def fallback_comments(image_description:, topics:)
      anchor = Array(topics).map(&:to_s).find(&:present?) || image_description.to_s.split(/[,.]/).first.to_s.downcase
      anchor = "this post" if anchor.blank?

      [
        "Okay this is a whole vibe 🔥",
        "Not gonna lie, this #{anchor} moment is clean 👏",
        "Love the energy on this one ✨",
        "This is low-key so good, great post 🙌",
        "Major main-feed energy right here 😮‍💨",
        "Ate this one, no notes 💯",
        "This made me stop scrolling fr 👀",
        "Super solid post, keep these coming 🚀"
      ]
    end
  end
end
