# frozen_string_literal: true

module Ai
  class CommentPolicyEngine
    BLOCKED_TERMS = %w[
      suicide
      self-harm
      kill
      nazi
      porn
      explicit
      racist
      slur
    ].freeze

    SENSITIVE_CLAIM_PATTERNS = [
      /\b(you\s+look|you\s+are)\s+(male|female|non-binary|trans|old|young)\b/i,
      /\b(age|gender|ethnicity|religion|nationality)\b/i
    ].freeze

    GENERIC_PHRASE_PATTERNS = [
      /\b(great content|nice post|good post|love the vibes?)\b/i,
      /\b(whole vibe|clean shot|on point|keep it up)\b/i,
      /\b(hot vibes?|story media moment)\b/i,
      /\b(ai-powered video|ai-enhanced video|video analysis is|local ai models?)\b/i
    ].freeze

    ROBOTIC_META_PATTERNS = [
      /\(\s*light question\s*\)/i,
      /\bintriguing\s+duo\b/i,
      /\b[a-z0-9_]+\s+and\s+[a-z0-9_]+,\s+an\s+[a-z0-9_]+\s+duo\b/i
    ].freeze

    NON_VISUAL_CONTEXT_TOKENS = %w[
      detected
      visual
      signals
      scene
      scenes
      transitions
      inferred
      topics
      story
      media
      context
      extracted
      local
      pipeline
      source
      account
      profile
      generation
      policy
      verified
      facts
      content
    ].freeze

    LOW_INFORMATION_TOKENS = %w[
      this
      that
      such
      very
      really
      vibe
      vibes
      mood
      energy
      nice
      good
      great
      wow
      amazing
      awesome
      cool
      clean
      love
      like
      post
      story
      frame
      shot
      moment
      content
      keep
      coming
      right
      here
      there
      only
      just
      looks
      look
      feel
      feels
    ].freeze

    def evaluate(suggestions:, historical_comments: [], context_keywords: [], max_suggestions: 8)
      accepted = []
      rejected = []
      history = Array(historical_comments).map(&:to_s)
      context_tokens = tokenize(Array(context_keywords).join(" "))
      recent_openers = Array(history).map { |row| opening_signature(row) }.reject(&:blank?)

      Array(suggestions).each do |raw|
        text = normalize_comment(raw)
        next if text.blank?

        reasons = []
        reasons << "blocked_term" if blocked_term?(text)
        reasons << "sensitive_claim" if sensitive_claim?(text)
        reasons << "history_repetition" if repetitive_against_history?(text, history)
        reasons << "recent_opening_reuse" if repetitive_opening?(text, recent_openers: recent_openers, accepted: accepted)
        reasons << "batch_similarity" if repetitive_within_batch?(text, accepted: accepted)
        reasons << "generic_phrase" if generic_phrase?(text)
        reasons << "robotic_meta_phrase" if robotic_meta_phrase?(text)
        reasons << "weak_visual_grounding" if weak_visual_grounding?(text, context_tokens)
        reasons << "low_information" if low_information_comment?(text)

        if reasons.any?
          rejected << { comment: text, reasons: reasons }
          next
        end

        accepted << text
      end

      {
        accepted: accepted.uniq.first(max_suggestions.to_i.clamp(1, 20)),
        rejected: rejected
      }
    end

    private

    def normalize_comment(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return nil if text.blank?

      text.byteslice(0, 140)
    end

    def blocked_term?(comment)
      lc = comment.to_s.downcase
      BLOCKED_TERMS.any? { |term| lc.include?(term) }
    end

    def sensitive_claim?(comment)
      SENSITIVE_CLAIM_PATTERNS.any? { |pattern| comment.to_s.match?(pattern) }
    end

    def generic_phrase?(comment)
      GENERIC_PHRASE_PATTERNS.any? { |pattern| comment.to_s.match?(pattern) }
    end

    def robotic_meta_phrase?(comment)
      ROBOTIC_META_PATTERNS.any? { |pattern| comment.to_s.match?(pattern) }
    end

    def repetitive_against_history?(comment, history)
      candidate_tokens = tokenize(comment)
      return false if candidate_tokens.empty?

      Array(history).any? do |past|
        score = jaccard(candidate_tokens, tokenize(past))
        score >= 0.82
      end
    end

    def repetitive_within_batch?(comment, accepted:)
      tokens = tokenize(comment)
      return false if tokens.empty?

      Array(accepted).any? do |row|
        score = jaccard(tokens, tokenize(row))
        score >= 0.75
      end
    end

    def repetitive_opening?(comment, recent_openers:, accepted:)
      signature = opening_signature(comment)
      return false if signature.blank?

      accepted_openers = Array(accepted).map { |row| opening_signature(row) }.reject(&:blank?)
      recent_openers.include?(signature) || accepted_openers.include?(signature)
    end

    def opening_signature(comment)
      tokenize(comment).first(3).join(" ")
    end

    def weak_visual_grounding?(comment, context_tokens)
      meaningful_context = Array(context_tokens).map(&:to_s).reject { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }
      return false if meaningful_context.empty?

      candidate_tokens = tokenize(comment)
      return true if candidate_tokens.empty?

      overlap = (candidate_tokens & meaningful_context).size
      overlap <= 0
    end

    def low_information_comment?(comment)
      tokens = tokenize(comment)
      return true if tokens.empty?

      meaningful = tokens - LOW_INFORMATION_TOKENS
      meaningful.size < 2
    end

    def tokenize(value)
      value.to_s.downcase.scan(/[a-z0-9]+/).uniq
    end

    def jaccard(a, b)
      return 0.0 if a.empty? || b.empty?

      intersection = (a & b).length
      union = (a | b).length
      return 0.0 if union <= 0

      intersection.to_f / union.to_f
    end
  end
end
