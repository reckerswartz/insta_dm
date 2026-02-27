require "json"
require "net/http"

module Ai
  class LocalEngagementCommentGenerator
    DEFAULT_MODEL = Ai::ModelDefaults.comment_model.freeze
    DEFAULT_FAST_MODEL = DEFAULT_MODEL
    DEFAULT_QUALITY_MODEL = ENV.fetch("OLLAMA_COMMENT_QUALITY_MODEL", Ai::ModelDefaults.quality_model).freeze
    MIN_SUGGESTIONS = 3
    MAX_SUGGESTIONS = 8
    PRIMARY_TEMPERATURE = ENV.fetch("LLM_COMMENT_PRIMARY_TEMPERATURE", "0.65").to_f.clamp(0.1, 1.2)
    QUALITY_TEMPERATURE = ENV.fetch("LLM_COMMENT_QUALITY_TEMPERATURE", "0.55").to_f.clamp(0.1, 1.2)
    PRIMARY_MAX_TOKENS = ENV.fetch("LLM_COMMENT_PRIMARY_MAX_TOKENS", "220").to_i.clamp(120, 520)
    PRIMARY_RETRY_MAX_TOKENS = ENV.fetch("LLM_COMMENT_PRIMARY_RETRY_MAX_TOKENS", "180").to_i.clamp(100, 420)
    QUALITY_MAX_TOKENS = ENV.fetch("LLM_COMMENT_QUALITY_MAX_TOKENS", "260").to_i.clamp(150, 620)
    QUALITY_RETRY_MAX_TOKENS = ENV.fetch("LLM_COMMENT_QUALITY_RETRY_MAX_TOKENS", "220").to_i.clamp(120, 520)
    RESPONSE_FORMAT = "json".freeze
    ESCALATION_MIN_ACCEPTED_SUGGESTIONS = ENV.fetch("LLM_COMMENT_ESCALATION_MIN_ACCEPTED", "5").to_i.clamp(MIN_SUGGESTIONS, MAX_SUGGESTIONS)
    ESCALATION_MAX_REJECT_RATIO = ENV.fetch("LLM_COMMENT_ESCALATION_MAX_REJECT_RATIO", "0.45").to_f.clamp(0.0, 1.0)
    ESCALATION_MIN_GROUNDED_RATIO = ENV.fetch("LLM_COMMENT_ESCALATION_MIN_GROUNDED_RATIO", "0.55").to_f.clamp(0.0, 1.0)
    MIN_DETECTION_ANCHOR_CONFIDENCE = 0.38
    STRONG_DETECTION_ANCHOR_CONFIDENCE = 0.55
    STORY_MODE_HINTS = {
      "text_heavy" => %w[promo offer discount loan bank apr interest apply sale starting rate money],
      "sports" => %w[sport sports match game stadium cricket football basketball athlete bat ball goal jersey],
      "food" => %w[food dish meal plate bowl drink recipe restaurant cafe kitchen cooking],
      "group" => %w[group family friends crowd team together gathering],
      "repost_meme" => %w[repost meme status quote brother single screenshot forward shared]
    }.freeze
    GENERIC_OBJECT_ANCHORS = %w[
      person
      people
      human
      man
      woman
      boy
      girl
      sink
      room
      wall
      floor
      table
      corner
      interior
    ].freeze
    NON_VISUAL_CONTEXT_TOKENS = %w[
      detected
      visual
      signals
      scene
      scenes
      transitions
      inferred
      element
      elements
      lifestyle
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
    MIN_MEDIA_ANCHORS_BEFORE_CONTEXT_BLEND = 6
    TRANSIENT_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED
    ].freeze
    MAX_CONTEXT_JSON_CHARS = ENV.fetch("LLM_COMMENT_MAX_CONTEXT_JSON_CHARS", "1800").to_i.clamp(1200, 12000)
    TARGET_CONTEXT_JSON_CHARS = ENV.fetch("LLM_COMMENT_TARGET_CONTEXT_JSON_CHARS", "1300").to_i.clamp(900, 10000)

    def initialize(ollama_client:, model: nil, policy_engine: nil)
      @ollama_client = ollama_client
      @primary_model = model.to_s.presence || ENV.fetch("OLLAMA_COMMENT_MODEL", DEFAULT_FAST_MODEL).to_s.presence || DEFAULT_FAST_MODEL
      @quality_model = ENV.fetch("OLLAMA_COMMENT_QUALITY_MODEL", ENV.fetch("OLLAMA_QUALITY_MODEL", DEFAULT_QUALITY_MODEL)).to_s.presence || @primary_model
      @enable_model_escalation = ActiveModel::Type::Boolean.new.cast(ENV.fetch("LLM_COMMENT_ENABLE_MODEL_ESCALATION", "false"))
      @model = @primary_model
      @policy_engine = policy_engine || Ai::CommentPolicyEngine.new
    end

    def generate!(post_payload:, image_description:, topics:, author_type:, channel: "post", historical_comments: [], historical_context: nil, historical_story_context: [], local_story_intelligence: {}, historical_comparison: {}, cv_ocr_evidence: {}, verified_story_facts: {}, story_ownership_classification: {}, generation_policy: {}, profile_preparation: {}, verified_profile_history: [], conversational_voice: {}, scored_context: {}, **_extra)
      @last_prompt_inputs = {}
      if generation_policy.is_a?(Hash) && generation_policy.key?(:allow_comment) && !ActiveModel::Type::Boolean.new.cast(generation_policy[:allow_comment] || generation_policy["allow_comment"])
        return {
          model: @model,
          prompt: nil,
          raw: {},
          source: "policy",
          status: "blocked_by_policy",
          fallback_used: false,
          error_message: generation_policy[:reason].to_s.presence || generation_policy["reason"].to_s.presence || "Generation blocked by verified story policy.",
          comment_suggestions: [],
          prompt_inputs: {},
          policy_diagnostics: {}
        }
      end

      prompt = build_prompt(
        post_payload: post_payload,
        image_description: image_description,
        topics: topics,
        author_type: author_type,
        channel: channel,
        historical_comments: historical_comments,
        historical_context: historical_context,
        historical_story_context: historical_story_context,
        local_story_intelligence: local_story_intelligence,
        historical_comparison: historical_comparison,
        cv_ocr_evidence: cv_ocr_evidence,
        verified_story_facts: verified_story_facts,
        story_ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        profile_preparation: profile_preparation,
        verified_profile_history: verified_profile_history,
        conversational_voice: conversational_voice,
        scored_context: scored_context
      )
      prompt_inputs = @last_prompt_inputs.is_a?(Hash) ? @last_prompt_inputs.deep_dup : {}
      @last_topics_for_policy = Array(topics).map(&:to_s)
      @last_image_description_for_policy = image_description.to_s

      primary_pass = execute_model_pass(
        model: @primary_model,
        prompt: prompt,
        tier: :primary,
        topics: topics,
        image_description: image_description,
        historical_comments: historical_comments,
        scored_context: scored_context,
        verified_story_facts: verified_story_facts,
        channel: channel
      )

      quality_pass = nil
      escalated = false
      escalation_reasons = escalation_reasons_for(pass: primary_pass)
      if should_escalate_to_quality_model?(reasons: escalation_reasons)
        quality_pass = execute_model_pass(
          model: @quality_model,
          prompt: prompt,
          tier: :quality,
          topics: topics,
          image_description: image_description,
          historical_comments: historical_comments,
          scored_context: scored_context,
          verified_story_facts: verified_story_facts,
          channel: channel
        )
        escalated = true
      end

      selected_pass = choose_best_model_pass(primary_pass: primary_pass, quality_pass: quality_pass)
      suggestions = Array(selected_pass[:suggestions]).first(MAX_SUGGESTIONS)
      policy_diagnostics = selected_pass[:policy_diagnostics].is_a?(Hash) ? selected_pass[:policy_diagnostics] : {}
      llm_telemetry = merge_model_telemetry(
        selected_pass: selected_pass,
        primary_pass: primary_pass,
        quality_pass: quality_pass,
        escalated: escalated,
        escalation_reasons: escalation_reasons
      )

      if suggestions.size < MIN_SUGGESTIONS
        fallback_result = policy_checked_fallback(
          image_description: image_description,
          topics: topics,
          channel: channel,
          scored_context: scored_context,
          verified_story_facts: verified_story_facts,
          historical_comments: historical_comments
        )
        return {
          model: selected_pass[:model] || @model,
          prompt: prompt,
          raw: selected_pass[:raw].is_a?(Hash) ? selected_pass[:raw] : {},
          source: "fallback",
          status: "fallback_used",
          fallback_used: true,
          llm_telemetry: llm_telemetry,
          error_message: "Generated suggestions were insufficient (#{suggestions.size}/#{MIN_SUGGESTIONS})",
          comment_suggestions: fallback_result[:suggestions],
          prompt_inputs: prompt_inputs,
          policy_diagnostics: fallback_result[:policy_diagnostics].is_a?(Hash) ? fallback_result[:policy_diagnostics] : policy_diagnostics
        }
      end

      {
        model: selected_pass[:model] || @model,
        prompt: prompt,
        raw: selected_pass[:raw].is_a?(Hash) ? selected_pass[:raw] : {},
        source: "ollama",
        status: "ok",
        fallback_used: false,
        llm_telemetry: llm_telemetry,
        error_message: nil,
        comment_suggestions: suggestions.first(MAX_SUGGESTIONS),
        prompt_inputs: prompt_inputs,
        policy_diagnostics: policy_diagnostics
      }
    rescue *TRANSIENT_ERRORS
      raise
    rescue StandardError => e
      fallback_result = policy_checked_fallback(
        image_description: image_description,
        topics: topics,
        channel: channel,
        scored_context: scored_context,
        verified_story_facts: verified_story_facts,
        historical_comments: historical_comments
      )
      {
        model: @model,
        prompt: prompt,
        raw: {},
        source: "fallback",
        status: "error_fallback",
        fallback_used: true,
        llm_telemetry: {
          prompt_chars: prompt.to_s.length
        },
        error_message: e.message.to_s,
        comment_suggestions: fallback_result[:suggestions],
        prompt_inputs: (@last_prompt_inputs.is_a?(Hash) ? @last_prompt_inputs : {}),
        policy_diagnostics: fallback_result[:policy_diagnostics].is_a?(Hash) ? fallback_result[:policy_diagnostics] : {}
      }
    end

    private

    def build_prompt(post_payload:, image_description:, topics:, author_type:, channel:, historical_comments:, historical_context:, historical_story_context:, local_story_intelligence:, historical_comparison:, cv_ocr_evidence:, verified_story_facts:, story_ownership_classification:, generation_policy:, profile_preparation: {}, verified_profile_history: [], conversational_voice: {}, scored_context: {})
      tone_profile = Ai::CommentToneProfile.for(channel)
      verified_story_facts = compact_verified_story_facts(
        verified_story_facts,
        local_story_intelligence: local_story_intelligence,
        cv_ocr_evidence: cv_ocr_evidence
      )
      story_ownership_classification = compact_story_ownership_classification(story_ownership_classification)
      generation_policy = compact_generation_policy(generation_policy)
      historical_comparison = compact_historical_comparison(historical_comparison)
      compact_story_history = compact_historical_story_context(historical_story_context)
      profile_summary = compact_author_profile(post_payload[:author_profile], author_type: author_type)
      profile_preparation = compact_profile_preparation(profile_preparation)
      verified_profile_history = compact_verified_profile_history(verified_profile_history)
      conversational_voice = compact_conversational_voice(conversational_voice)
      scored_context = compact_scored_context(scored_context)
      occasion_context = build_occasion_context(
        post_payload: post_payload,
        topics: topics,
        image_description: image_description
      )
      tone_plan = build_tone_plan(channel: channel, scored_context: scored_context, occasion_context: occasion_context)
      situational_cues = detect_situational_cues(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        historical_comparison: historical_comparison
      )
      content_mode = classify_story_content_mode(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts
      )
      face_count = extract_face_count(verified_story_facts)
      visual_anchors = build_visual_anchors(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        scored_context: scored_context
      )
      @last_prompt_inputs = build_prompt_input_summary(
        topics: topics,
        visual_anchors: visual_anchors,
        image_description: image_description,
        verified_story_facts: verified_story_facts,
        scored_context: scored_context,
        situational_cues: situational_cues,
        content_mode: content_mode
      )

      context_json = {
        task: "instagram_#{Ai::CommentToneProfile.normalize(channel)}_comment_generation",
        channel: Ai::CommentToneProfile.normalize(channel),
        output_contract: {
          format: "strict_json",
          count: 8,
          max_chars_per_comment: 140
        },
        tone_profile: tone_profile,
        voice_directives: gen_z_voice_directives(
          channel: channel,
          story_ownership_classification: story_ownership_classification
        ),
        tone_plan: tone_plan,
        occasion_context: occasion_context,
        situational_cues: situational_cues,
        profile: profile_summary,
        profile_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        scored_context: scored_context,
        current_story: {
          image_description: truncate_text(image_description.to_s, max: 180),
          topics: Array(topics).map(&:to_s).reject(&:blank?).uniq.first(6),
          visual_anchors: visual_anchors.first(8),
          content_mode: content_mode,
          face_count: face_count,
          verified_story_facts: verified_story_facts,
          ownership: story_ownership_classification,
          generation_policy: generation_policy
        },
        historical_context: {
          comparison: historical_comparison,
          recent_story_patterns: compact_story_history,
          recent_profile_history: verified_profile_history,
          recent_comments: Array(historical_comments).map { |value| truncate_text(value.to_s, max: 90) }.reject(&:blank?).first(4),
          summary: truncate_text(historical_context.to_s, max: 180)
        }
      }
      context_json = compact_prompt_context(context_json)

      <<~PROMPT
        Generate Instagram comments from CONTEXT_JSON only.
        No fabrication, no hidden metadata, and no assumptions outside verified_story_facts.
        If generation_policy.allow_comment is false, return an empty list.
        If ownership is not owned_by_profile, keep comments neutral and non-personal.

        Mode: #{Ai::CommentToneProfile.normalize(channel)}
        Tone guidance: #{tone_profile[:guidance]}

        Requirements:
        - Return strict JSON only with key "comment_suggestions"
        - Exactly 8 suggestions, each <= 140 chars
        - Speak directly to the creator: prefer second-person language ("you"/"your") or direct reactions ("this is ...")
        - Never describe the creator in third person (avoid "that person", "he", "she", "they", "everyone looks")
        - Every suggestion must reference current_story.topics or current_story.visual_anchors
        - Sound natural, friendly, and socially conversational for a Gen Z audience
        - Avoid mechanical descriptions and camera-analysis wording like "this frame", "strong composition", or "detected objects"
        - Use light emoji naturally in 2-4 suggestions max, with at most 1 emoji per suggestion
        - Add a relatable personal touch while staying grounded in verified context
        - Keep at least 3 suggestions neutral-safe
        - Include 1-2 light conversational questions
        - If conversational_voice.recent_incoming_messages exists, align with that topic context without copying message text
        - Avoid explicit/adult/sensitive-trait language
        - Avoid duplicate openings and avoid repeating prior comments

        CONTEXT_JSON:
        #{JSON.generate(context_json)}
      PROMPT
    end

    def build_llm_telemetry(prompt:, response_payload:)
      {
        prompt_chars: prompt.to_s.length,
        prompt_eval_count: (response_payload["prompt_eval_count"] || response_payload[:prompt_eval_count]).to_i,
        eval_count: (response_payload["eval_count"] || response_payload[:eval_count]).to_i,
        total_duration_ns: (response_payload["total_duration"] || response_payload[:total_duration]).to_i,
        load_duration_ns: (response_payload["load_duration"] || response_payload[:load_duration]).to_i
      }
    rescue StandardError
      {
        prompt_chars: prompt.to_s.length
      }
    end

    def execute_model_pass(model:, prompt:, tier:, topics:, image_description:, historical_comments:, scored_context:, verified_story_facts:, channel:)
      temperature = tier == :quality ? QUALITY_TEMPERATURE : PRIMARY_TEMPERATURE
      max_tokens = tier_token_budget(tier: tier, prompt: prompt)
      retry_max_tokens = tier_retry_token_budget(tier: tier, prompt: prompt)

      resp = generate_with_json_format(
        model: model,
        prompt: prompt,
        temperature: temperature,
        max_tokens: max_tokens
      )
      telemetry = build_llm_telemetry(prompt: prompt, response_payload: resp)

      parsed_suggestions = parse_comment_suggestions(resp)
      evaluation = evaluate_suggestions(
        suggestions: parsed_suggestions,
        historical_comments: historical_comments,
        scored_context: scored_context,
        channel: channel,
        include_diagnostics: true
      )
      suggestions = diversify_suggestions(
        suggestions: evaluation[:accepted],
        topics: topics,
        image_description: image_description,
        channel: channel,
        scored_context: scored_context
      )

      retry_used = false
      if suggestions.size < MIN_SUGGESTIONS
        retry_resp = generate_with_json_format(
          model: model,
          prompt: "#{prompt}\n\nReturn strict JSON only. Ensure 8 non-empty suggestions and follow voice_directives.",
          temperature: [temperature - 0.15, 0.2].max,
          max_tokens: retry_max_tokens
        )
        telemetry[:retry] = build_llm_telemetry(prompt: prompt, response_payload: retry_resp)
        retry_parsed = parse_comment_suggestions(retry_resp)
        retry_evaluation = evaluate_suggestions(
          suggestions: retry_parsed,
          historical_comments: historical_comments,
          scored_context: scored_context,
          channel: channel,
          include_diagnostics: true
        )
        retry_suggestions = diversify_suggestions(
          suggestions: retry_evaluation[:accepted],
          topics: topics,
          image_description: image_description,
          channel: channel,
          scored_context: scored_context
        )
        if retry_suggestions.size >= suggestions.size
          resp = retry_resp
          evaluation = retry_evaluation
          suggestions = retry_suggestions
          retry_used = true
        end
      end

      {
        model: model,
        raw: resp,
        suggestions: suggestions.first(MAX_SUGGESTIONS),
        telemetry: telemetry,
        accepted_count: suggestions.size,
        parsed_count: evaluation[:raw_count],
        rejected_count: evaluation[:rejected_count],
        reject_ratio: evaluation[:reject_ratio],
        grounded_ratio: grounded_suggestion_ratio(
          suggestions: suggestions,
          topics: topics,
          image_description: image_description,
          verified_story_facts: verified_story_facts,
          scored_context: scored_context
        ),
        policy_diagnostics: summarize_policy_diagnostics(evaluation),
        retry_used: retry_used,
        tier: tier.to_s
      }
    end

    def tier_token_budget(tier:, prompt:)
      baseline = tier == :quality ? QUALITY_MAX_TOKENS : PRIMARY_MAX_TOKENS
      prompt_chars = prompt.to_s.length
      return [baseline - 70, 80].max if prompt_chars > 9000
      return [baseline - 40, 80].max if prompt_chars > 7000
      return [baseline - 20, 80].max if prompt_chars > 5000

      baseline
    end

    def tier_retry_token_budget(tier:, prompt:)
      baseline = tier == :quality ? QUALITY_RETRY_MAX_TOKENS : PRIMARY_RETRY_MAX_TOKENS
      prompt_chars = prompt.to_s.length
      return [baseline - 40, 60].max if prompt_chars > 9000
      return [baseline - 20, 60].max if prompt_chars > 7000

      baseline
    end

    def generate_with_json_format(model:, prompt:, temperature:, max_tokens:)
      @ollama_client.generate(
        model: model,
        prompt: prompt,
        temperature: temperature,
        max_tokens: max_tokens,
        format: RESPONSE_FORMAT
      )
    rescue ArgumentError => e
      raise unless e.message.to_s.include?("unknown keyword: :format")

      @ollama_client.generate(
        model: model,
        prompt: prompt,
        temperature: temperature,
        max_tokens: max_tokens
      )
    end

    def escalation_reasons_for(pass:)
      reasons = []
      accepted_count = pass[:accepted_count].to_i
      reject_ratio = pass[:reject_ratio].to_f
      grounded_ratio = pass[:grounded_ratio].to_f

      reasons << "low_accepted_count" if accepted_count < ESCALATION_MIN_ACCEPTED_SUGGESTIONS
      reasons << "high_reject_ratio" if reject_ratio > ESCALATION_MAX_REJECT_RATIO
      reasons << "weak_grounding" if grounded_ratio.positive? && grounded_ratio < ESCALATION_MIN_GROUNDED_RATIO
      reasons
    end

    def should_escalate_to_quality_model?(reasons:)
      return false unless @enable_model_escalation
      return false if reasons.empty?
      return false if @quality_model.to_s.blank?
      return false if @quality_model.to_s == @primary_model.to_s

      true
    end

    def choose_best_model_pass(primary_pass:, quality_pass:)
      return primary_pass unless quality_pass.is_a?(Hash)

      primary_score = model_pass_score(primary_pass)
      quality_score = model_pass_score(quality_pass)
      quality_score >= primary_score ? quality_pass : primary_pass
    end

    def model_pass_score(pass)
      accepted = pass[:accepted_count].to_i
      grounded = pass[:grounded_ratio].to_f
      reject_ratio = pass[:reject_ratio].to_f
      retry_penalty = pass[:retry_used] ? 0.2 : 0.0

      accepted + (grounded * 2.5) - (reject_ratio * 2.2) - retry_penalty
    end

    def merge_model_telemetry(selected_pass:, primary_pass:, quality_pass:, escalated:, escalation_reasons:)
      selected = selected_pass[:telemetry].is_a?(Hash) ? selected_pass[:telemetry].deep_dup : {}
      selected[:routing] = {
        primary_model: @primary_model,
        quality_model: @quality_model,
        selected_model: selected_pass[:model].to_s,
        selected_tier: selected_pass[:tier].to_s,
        escalated: escalated,
        escalation_reasons: escalation_reasons,
        primary_stats: compact_pass_stats(primary_pass),
        quality_stats: compact_pass_stats(quality_pass)
      }.compact
      selected
    end

    def compact_pass_stats(pass)
      return nil unless pass.is_a?(Hash)

      {
        model: pass[:model].to_s,
        accepted_count: pass[:accepted_count].to_i,
        parsed_count: pass[:parsed_count].to_i,
        rejected_count: pass[:rejected_count].to_i,
        reject_ratio: pass[:reject_ratio].to_f.round(3),
        grounded_ratio: pass[:grounded_ratio].to_f.round(3),
        retry_used: ActiveModel::Type::Boolean.new.cast(pass[:retry_used])
      }
    end

    def gen_z_voice_directives(channel:, story_ownership_classification:)
      ownership = story_ownership_classification.is_a?(Hash) ? story_ownership_classification : {}
      ownership_label = (ownership[:label] || ownership["label"]).to_s

      {
        target_audience: "gen_z_social",
        channel: Ai::CommentToneProfile.normalize(channel),
        style: [
          "Write like a real Instagram reply from a friend.",
          "Use natural contractions and casual social phrasing.",
          "Keep it warm, context-aware, and not overhyped."
        ],
        emoji_policy: {
          min_suggestions_with_emoji: 2,
          max_suggestions_with_emoji: 4,
          max_emoji_per_comment: 1
        },
        avoid_phrases: [
          "this frame",
          "strong composition",
          "detected objects",
          "visual signals",
          "clean shot"
        ],
        perspective: "direct_second_person",
        avoid_third_person_subjects: [
          "that person",
          "he",
          "she",
          "they",
          "everyone looks"
        ],
        neutral_only: ownership_label.present? && ownership_label != "owned_by_profile"
      }
    end

    def grounded_suggestion_ratio(suggestions:, topics:, image_description:, verified_story_facts:, scored_context:)
      anchors = build_visual_anchors(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        scored_context: scored_context
      )
      anchor_tokens = []
      anchor_tokens.concat(Array(topics).flat_map { |row| tokenize_text(row) })
      anchor_tokens.concat(Array(anchors).flat_map { |row| tokenize_text(row) })
      anchor_tokens.concat(extract_keywords_from_text(image_description.to_s))
      anchor_tokens = anchor_tokens.uniq.reject { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }
      return 1.0 if anchor_tokens.empty?

      rows = Array(suggestions).map(&:to_s).reject(&:blank?)
      return 0.0 if rows.empty?

      grounded_count = rows.count do |comment|
        (tokenize_text(comment) & anchor_tokens).any?
      end
      grounded_count.to_f / rows.size.to_f
    rescue StandardError
      0.0
    end

    def evaluate_suggestions(suggestions:, historical_comments:, scored_context: {}, channel: "post", include_diagnostics: false)
      memory_comments = []
      memory_comments.concat(Array(historical_comments))
      memory_comments.concat(Array(scored_context.dig(:engagement_memory, :recent_generated_comments)))
      memory_comments.concat(Array(scored_context.dig("engagement_memory", "recent_generated_comments")))
      memory_comments.concat(Array(scored_context.dig(:engagement_memory, :recent_story_generated_comments)))
      memory_comments.concat(Array(scored_context.dig("engagement_memory", "recent_story_generated_comments")))

      context_keywords = []
      context_keywords.concat(Array(@last_topics_for_policy))
      context_keywords.concat(extract_keywords_from_text(@last_image_description_for_policy))
      context_keywords.concat(Array(scored_context[:context_keywords] || scored_context["context_keywords"]).map(&:to_s))
      context_keywords.concat(
        Array(scored_context[:prioritized_signals] || scored_context["prioritized_signals"]).first(8).flat_map do |row|
          value = row.is_a?(Hash) ? (row[:value] || row["value"]).to_s : row.to_s
          extract_keywords_from_text(value)
        end
      )
      result = @policy_engine.evaluate(
        suggestions: suggestions,
        historical_comments: memory_comments,
        context_keywords: context_keywords,
        max_suggestions: MAX_SUGGESTIONS,
        channel: channel,
        require_direct_address: Ai::CommentToneProfile.normalize(channel) == "story"
      )
      accepted = Array(result[:accepted])
      return accepted unless include_diagnostics

      rejected = Array(result[:rejected])
      {
        accepted: accepted,
        rejected: rejected,
        raw_count: Array(suggestions).size,
        rejected_count: rejected.size,
        reject_ratio: (Array(suggestions).size > 0 ? (rejected.size.to_f / Array(suggestions).size.to_f) : 0.0)
      }
    end

    def summarize_policy_diagnostics(evaluation)
      diagnostics = evaluation.is_a?(Hash) ? evaluation : {}
      rejected = Array(diagnostics[:rejected]).select { |row| row.is_a?(Hash) }
      reason_counts = Hash.new(0)
      rejected.each do |row|
        Array(row[:reasons] || row["reasons"]).each do |reason|
          token = reason.to_s.strip
          next if token.blank?
          reason_counts[token] += 1
        end
      end

      {
        raw_count: diagnostics[:raw_count].to_i,
        rejected_count: diagnostics[:rejected_count].to_i,
        reject_ratio: diagnostics[:reject_ratio].to_f.round(3),
        rejected_reason_counts: reason_counts.sort_by { |_, count| -count }.to_h,
        rejected_samples: rejected.first(5).map do |row|
          {
            comment: row[:comment].to_s,
            reasons: Array(row[:reasons] || row["reasons"]).map(&:to_s).reject(&:blank?).first(4)
          }
        end
      }
    rescue StandardError
      {}
    end

    def diversify_suggestions(suggestions:, topics:, image_description:, channel:, scored_context:)
      rows = Array(suggestions).map { |value| normalize_comment(value) }.compact
      return [] if rows.empty?

      selected = []
      used_openers = Array(scored_context.dig(:engagement_memory, :recent_openers)) +
        Array(scored_context.dig("engagement_memory", "recent_openers"))
      used_openers = used_openers.map(&:to_s)

      buckets = rows.group_by { |text| tone_bucket(text) }
      order = %w[observational supportive playful celebratory curious]

      loop do
        added = false
        order.each do |bucket|
          candidate = Array(buckets[bucket]).find do |text|
            !selected.include?(text) &&
              !used_openers.include?(opening_signature(text)) &&
              !too_similar_to_selected?(text, selected)
          end
          next unless candidate

          selected << candidate
          used_openers << opening_signature(candidate)
          added = true
          break if selected.size >= MAX_SUGGESTIONS
        end
        break if selected.size >= MAX_SUGGESTIONS || !added
      end

      if selected.none? { |row| row.include?("?") }
        question = build_light_question(topics: topics, image_description: image_description, channel: channel)
        selected << question if question.present?
      end

      selected.uniq.first(MAX_SUGGESTIONS)
    end

    def normalize_comment(value)
      text = strip_markdown_fences(value.to_s)
      text = text.gsub(/\A(?:[-*•]|\d+[.)])\s*/, "").strip
      text = text.gsub(/\s+/, " ").strip
      text = strip_trailing_separator(text)
      text = strip_wrapping_quotes(text)
      return nil if text.blank?
      return nil if scaffolding_artifact?(text)

      text.byteslice(0, 140)
    end

    def parse_comment_suggestions(response_payload)
      raw = response_payload.is_a?(Hash) ? (response_payload["response"] || response_payload[:response]) : response_payload
      return [] if raw.blank?

      parsed = parse_comment_suggestions_payload(raw)
      suggestions = extracted_comment_suggestions(parsed)
      return suggestions if suggestions.any?

      parse_comment_suggestions_from_text(raw.to_s)
    rescue StandardError
      []
    end

    def parse_comment_suggestions_payload(raw)
      return raw if raw.is_a?(Hash) || raw.is_a?(Array)

      text = raw.to_s
      return {} if text.blank?

      JSON.parse(text)
    rescue JSON::ParserError
      parse_embedded_comment_json(text)
    end

    def parse_embedded_comment_json(text)
      object_start = text.index("{")
      object_end = text.rindex("}")
      if object_start && object_end && object_end > object_start
        candidate = text[object_start..object_end]
        parsed = JSON.parse(candidate) rescue nil
        return parsed if parsed.is_a?(Hash)
      end

      array_start = text.index("[")
      array_end = text.rindex("]")
      if array_start && array_end && array_end > array_start
        candidate = text[array_start..array_end]
        parsed = JSON.parse(candidate) rescue nil
        return { "comment_suggestions" => parsed } if parsed.is_a?(Array)
      end

      {}
    rescue StandardError
      {}
    end

    def extracted_comment_suggestions(parsed)
      rows =
        if parsed.is_a?(Hash)
          parsed["comment_suggestions"] || parsed[:comment_suggestions]
        elsif parsed.is_a?(Array)
          parsed
        else
          []
        end

      Array(rows).map { |value| normalize_comment(value) }.compact.uniq.first(MAX_SUGGESTIONS)
    rescue StandardError
      []
    end

    def parse_comment_suggestions_from_text(text)
      rows = text.to_s.lines.filter_map do |line|
        row = line.to_s.strip
        next if row.blank?
        next if row.start_with?("```")

        normalize_comment(row)
      end

      rows.uniq.first(MAX_SUGGESTIONS)
    end

    def strip_markdown_fences(text)
      cleaned = text.to_s.strip
      cleaned = cleaned.sub(/\A```(?:json)?\s*/i, "")
      cleaned = cleaned.sub(/\s*```\z/, "")
      cleaned.strip
    end

    def strip_trailing_separator(text)
      text.to_s.strip.sub(/,\z/, "").strip
    end

    def strip_wrapping_quotes(text)
      cleaned = text.to_s.strip
      loop do
        break if cleaned.length < 2
        break unless (cleaned.start_with?("\"") && cleaned.end_with?("\"")) ||
          (cleaned.start_with?("'") && cleaned.end_with?("'")) ||
          (cleaned.start_with?("`") && cleaned.end_with?("`"))

        cleaned = cleaned[1...-1].to_s.strip
      end
      cleaned
    end

    def scaffolding_artifact?(text)
      normalized = text.to_s.downcase.gsub(/\s+/, " ").strip
      return true if normalized.blank?
      return true if %w[{ } [ ]].include?(normalized)
      return true if normalized.match?(/\A["']?(comment_suggestions|suggestions?)["']?\s*:?\s*\[?\]?\s*\z/)
      return true if normalized.match?(/\Ahere(?:'s| are)\b.*\b(comment_suggestions|suggestions?|json)\b/)
      return true if normalized.match?(/\A(?:return\s+)?(?:strict\s+)?json(?:\s+only)?\.?\z/)

      false
    end

    def fallback_comments(image_description:, topics:, channel:, scored_context:, verified_story_facts:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      mode = classify_story_content_mode(
        image_description: image_description,
        topics: topics,
        verified_story_facts: facts
      )
      anchors = build_visual_anchors(
        image_description: image_description,
        topics: topics,
        verified_story_facts: facts,
        scored_context: scored_context
      )
      anchor = select_fallback_anchor(
        anchors: anchors,
        mode: mode,
        image_description: image_description,
        verified_story_facts: facts
      )

      case mode
      when "text_heavy"
        text_heavy_fallback_comments(anchor: anchor, channel: channel)
      when "sports"
        sports_fallback_comments(anchor: anchor, channel: channel)
      when "group"
        group_fallback_comments(anchor: anchor, channel: channel)
      when "food"
        food_fallback_comments(anchor: anchor, channel: channel)
      when "portrait"
        portrait_fallback_comments(anchor: anchor, channel: channel)
      when "repost_meme"
        repost_fallback_comments(anchor: anchor, channel: channel)
      else
        generic_fallback_comments(anchor: anchor, channel: channel)
      end
    end

    def policy_checked_fallback(image_description:, topics:, channel:, scored_context:, verified_story_facts:, historical_comments:)
      fallback_candidates = fallback_comments(
        image_description: image_description,
        topics: topics,
        channel: channel,
        scored_context: scored_context,
        verified_story_facts: verified_story_facts
      ).first(MAX_SUGGESTIONS)
      evaluation = evaluate_suggestions(
        suggestions: fallback_candidates,
        historical_comments: historical_comments,
        scored_context: scored_context,
        channel: channel,
        include_diagnostics: true
      )
      filtered = diversify_suggestions(
        suggestions: evaluation[:accepted],
        topics: topics,
        image_description: image_description,
        channel: channel,
        scored_context: scored_context
      ).first(MAX_SUGGESTIONS)
      filtered = emergency_fallback_comments(channel: channel, topics: topics) if filtered.empty?

      {
        suggestions: filtered.first(MAX_SUGGESTIONS),
        policy_diagnostics: summarize_policy_diagnostics(evaluation).merge(
          fallback_policy_applied: true,
          fallback_candidate_count: fallback_candidates.size
        )
      }
    rescue StandardError
      {
        suggestions: fallback_comments(
          image_description: image_description,
          topics: topics,
          channel: channel,
          scored_context: scored_context,
          verified_story_facts: verified_story_facts
        ).first(MAX_SUGGESTIONS),
        policy_diagnostics: {
          fallback_policy_applied: false
        }
      }
    end

    def emergency_fallback_comments(channel:, topics:)
      anchor = normalize_anchor(Array(topics).first) || "moment"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "Your #{anchor} moment feels natural and easy to connect with.",
          "You made this #{anchor} update feel clear and personal.",
          "What made you pick this #{anchor} moment to share?",
          "Your #{anchor} energy comes through right away."
        ]
      else
        [
          "This #{anchor} moment feels natural and easy to connect with.",
          "Strong #{anchor} update with a clear point of view.",
          "What inspired this #{anchor} moment?",
          "This #{anchor} share feels authentic."
        ]
      end
    end

    def detect_situational_cues(image_description:, topics:, verified_story_facts:, historical_comparison:)
      tokens = []
      tokens.concat(Array(topics).map(&:to_s))
      tokens.concat(Array(verified_story_facts[:topics] || verified_story_facts["topics"]).map(&:to_s))
      tokens.concat(Array(verified_story_facts[:hashtags] || verified_story_facts["hashtags"]).map(&:to_s))
      tokens.concat(Array(historical_comparison[:novel_topics] || historical_comparison["novel_topics"]).map(&:to_s))
      tokens.concat(extract_keywords_from_text(image_description.to_s))
      corpus = tokens.join(" ").downcase

      cues = []
      cues << "celebration" if corpus.match?(/\b(birthday|party|wedding|anniversary|celebrat|congrats|graduation)\b/)
      cues << "travel" if corpus.match?(/\b(travel|trip|vacation|beach|airport|hotel|flight|mountain|city)\b/)
      cues << "sports" if corpus.match?(/\b(match|stadium|cricket|football|basketball|athlete|game)\b/)
      cues << "text_heavy" if corpus.match?(/\b(offer|loan|bank|discount|sale|apply|promo)\b/)
      cues << "lifestyle" if corpus.match?(/\b(workout|gym|coffee|food|restaurant|fashion|outfit|selfcare|morning)\b/)
      cues << "social" if corpus.match?(/\b(friend|family|hangout|crew|together|date)\b/)
      cues << "creative" if corpus.match?(/\b(art|music|dance|shoot|photo|film|design)\b/)
      cues = [ "general" ] if cues.empty?
      cues.uniq.first(4)
    end

    def build_occasion_context(post_payload:, topics:, image_description:)
      post = post_payload.is_a?(Hash) ? (post_payload[:post] || post_payload["post"]) : {}
      post = {} unless post.is_a?(Hash)
      timestamp = parse_time(post[:taken_at] || post["taken_at"] || post[:occurred_at] || post["occurred_at"]) || Time.current
      month_day = timestamp.strftime("%m-%d")
      text_blob = "#{Array(topics).join(' ')} #{image_description}".downcase

      holiday = case month_day
      when "12-25" then "christmas"
      when "01-01" then "new_year"
      when "07-04" then "independence_day"
      when "10-31" then "halloween"
      when "02-14" then "valentines_day"
      else
        nil
      end

      inferred_event =
        if text_blob.match?(/\b(birthday|anniversary|graduation|wedding|party)\b/)
          "milestone"
        elsif text_blob.match?(/\b(travel|trip|vacation|airport|hotel)\b/)
          "travel"
        elsif text_blob.match?(/\b(festival|concert|game|match)\b/)
          "event"
        end

      {
        weekday: timestamp.strftime("%A").downcase,
        daypart: daypart_for(timestamp),
        month: timestamp.strftime("%B").downcase,
        holiday_hint: holiday,
        inferred_event: inferred_event
      }.compact
    end

    def build_tone_plan(channel:, scored_context:, occasion_context:)
      relationship = scored_context.dig(:engagement_memory, :relationship_familiarity) ||
        scored_context.dig("engagement_memory", "relationship_familiarity") || "neutral"
      daypart = occasion_context[:daypart].to_s
      event = occasion_context[:inferred_event].to_s

      styles = %w[observational supportive playful curious celebratory]
      styles.delete("playful") if relationship == "professional"
      styles.unshift("celebratory") if event == "milestone"
      styles.unshift("observational") if daypart == "morning"
      styles.unshift("supportive") if channel.to_s == "story"

      {
        relationship_familiarity: relationship,
        preferred_style_order: styles.uniq.first(5),
        include_light_question: true
      }
    end

    def extract_keywords_from_text(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
        .reject { |token| token.length < 4 }
        .reject { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }
        .uniq
        .first(24)
    end

    def truncate_text(value, max:)
      text = value.to_s.strip
      return text if text.length <= max

      "#{text.byteslice(0, max)}..."
    end

    def compact_prompt_context(payload)
      data = deep_clone_json(payload)
      return data if prompt_context_within_budget?(data)

      # Trim lower-signal historical slices first before removing current story context.
      if data[:historical_context].is_a?(Hash)
        data[:historical_context][:recent_profile_history] = Array(data[:historical_context][:recent_profile_history]).first(2)
        data[:historical_context][:recent_story_patterns] = Array(data[:historical_context][:recent_story_patterns]).first(2)
        data[:historical_context][:recent_comments] = Array(data[:historical_context][:recent_comments]).first(2)
        data[:historical_context][:summary] = truncate_text(data[:historical_context][:summary], max: 120)
      end
      if data[:scored_context].is_a?(Hash)
        data[:scored_context][:prioritized_signals] = Array(data[:scored_context][:prioritized_signals]).first(4)
      end
      if data[:current_story].is_a?(Hash)
        data[:current_story][:visual_anchors] = Array(data[:current_story][:visual_anchors]).first(6)
        data[:current_story][:topics] = Array(data[:current_story][:topics]).first(4)
        data[:current_story][:image_description] = truncate_text(data[:current_story][:image_description], max: 120)
      end
      return data if prompt_context_within_budget?(data, max_chars: TARGET_CONTEXT_JSON_CHARS)

      apply_aggressive_context_compaction!(data)
      return data if prompt_context_within_budget?(data)

      data[:conversational_voice] = compact_minimal_conversational_voice(data[:conversational_voice])
      data[:profile_preparation] = compact_minimal_profile_preparation(data[:profile_preparation])
      data[:historical_context][:comparison] = {} if data[:historical_context].is_a?(Hash)
      data
    rescue StandardError
      payload
    end

    def apply_aggressive_context_compaction!(data)
      if data[:scored_context].is_a?(Hash)
        data[:scored_context][:prioritized_signals] = Array(data[:scored_context][:prioritized_signals]).first(2)
        data[:scored_context][:context_keywords] = Array(data[:scored_context][:context_keywords]).first(8)
      end

      if data[:historical_context].is_a?(Hash)
        data[:historical_context][:recent_profile_history] = Array(data[:historical_context][:recent_profile_history]).first(1)
        data[:historical_context][:recent_story_patterns] = Array(data[:historical_context][:recent_story_patterns]).first(1)
        data[:historical_context][:recent_comments] = Array(data[:historical_context][:recent_comments]).first(1)
        data[:historical_context][:summary] = truncate_text(data[:historical_context][:summary], max: 90)
        data[:historical_context][:comparison] = {}
      end

      if data[:current_story].is_a?(Hash)
        data[:current_story][:visual_anchors] = Array(data[:current_story][:visual_anchors]).first(4)
        data[:current_story][:topics] = Array(data[:current_story][:topics]).first(3)
        data[:current_story][:verified_story_facts] = compact_verified_story_facts(
          data[:current_story][:verified_story_facts],
          local_story_intelligence: {},
          cv_ocr_evidence: {}
        )
      end

      if data[:conversational_voice].is_a?(Hash)
        data[:conversational_voice][:recent_incoming_messages] = Array(data[:conversational_voice][:recent_incoming_messages]).first(1)
      end
    end

    def prompt_context_within_budget?(payload, max_chars: MAX_CONTEXT_JSON_CHARS)
      JSON.generate(payload).length <= max_chars.to_i
    rescue StandardError
      true
    end

    def deep_clone_json(value)
      JSON.parse(JSON.generate(value), symbolize_names: true)
    rescue StandardError
      value
    end

    def compact_local_story_intelligence(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 600),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 600),
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(20),
        scenes: Array(data[:scenes] || data["scenes"]).first(20),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(20),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(20),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(20),
        source_account_reference: (data[:source_account_reference] || data["source_account_reference"]).to_s.presence,
        source_profile_ids: Array(data[:source_profile_ids] || data["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(10),
        media_type: (data[:media_type] || data["media_type"]).to_s.presence,
        face_count: (data[:face_count] || data["face_count"]).to_i,
        people: Array(data[:people] || data["people"]).first(10),
        object_detections: Array(data[:object_detections] || data["object_detections"]).first(25),
        ocr_blocks: Array(data[:ocr_blocks] || data["ocr_blocks"]).first(25)
      }.compact
    end

    def compact_cv_ocr_evidence(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(20),
        scenes: Array(data[:scenes] || data["scenes"]).first(20),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(20),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(20),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(20),
        source_account_reference: (data[:source_account_reference] || data["source_account_reference"]).to_s.presence,
        source_profile_ids: Array(data[:source_profile_ids] || data["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(10),
        media_type: (data[:media_type] || data["media_type"]).to_s.presence,
        face_count: (data[:face_count] || data["face_count"]).to_i,
        people: Array(data[:people] || data["people"]).first(10),
        object_detections: Array(data[:object_detections] || data["object_detections"]).first(25),
        ocr_blocks: Array(data[:ocr_blocks] || data["ocr_blocks"]).first(25),
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 600),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 600)
      }.compact
    end

    def compact_historical_comparison(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        shared_topics: Array(data[:shared_topics] || data["shared_topics"]).first(12),
        novel_topics: Array(data[:novel_topics] || data["novel_topics"]).first(12),
        shared_objects: Array(data[:shared_objects] || data["shared_objects"]).first(12),
        novel_objects: Array(data[:novel_objects] || data["novel_objects"]).first(12),
        shared_scenes: Array(data[:shared_scenes] || data["shared_scenes"]).first(12),
        novel_scenes: Array(data[:novel_scenes] || data["novel_scenes"]).first(12),
        recurring_hashtags: Array(data[:recurring_hashtags] || data["recurring_hashtags"]).first(12),
        recurring_mentions: Array(data[:recurring_mentions] || data["recurring_mentions"]).first(12),
        recurring_people_ids: Array(data[:recurring_people_ids] || data["recurring_people_ids"]).first(12),
        has_historical_overlap: ActiveModel::Type::Boolean.new.cast(data[:has_historical_overlap] || data["has_historical_overlap"])
      }
    end

    def compact_verified_story_facts(payload, local_story_intelligence:, cv_ocr_evidence:)
      data = payload.is_a?(Hash) ? payload : {}
      if data.blank?
        data = compact_cv_ocr_evidence(cv_ocr_evidence)
        data[:signal_score] = 0 unless data.key?(:signal_score)
      end

      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        signal_score: (data[:signal_score] || data["signal_score"]).to_i,
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 180),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 180),
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(10),
        object_detections: compact_object_detections(data[:object_detections] || data["object_detections"]),
        scenes: compact_scenes(data[:scenes] || data["scenes"]),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(8),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(8),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(8),
        detected_usernames: Array(data[:detected_usernames] || data["detected_usernames"]).map(&:to_s).reject(&:blank?).first(8),
        source_profile_references: Array(data[:source_profile_references] || data["source_profile_references"]).map(&:to_s).reject(&:blank?).first(8),
        share_status: (data[:share_status] || data["share_status"]).to_s.presence,
        meme_markers: Array(data[:meme_markers] || data["meme_markers"]).map(&:to_s).reject(&:blank?).first(6),
        face_count: (data[:face_count] || data["face_count"]).to_i,
        faces: compact_faces_payload(data[:faces] || data["faces"]),
        identity_verification: compact_identity_verification(data[:identity_verification] || data["identity_verification"])
      }
    end

    def compact_story_ownership_classification(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        label: data[:label] || data["label"],
        decision: data[:decision] || data["decision"],
        confidence: (data[:confidence] || data["confidence"]).to_f,
        summary: truncate_text(data[:summary] || data["summary"], max: 220),
        reason_codes: Array(data[:reason_codes] || data["reason_codes"]).first(10),
        detected_external_usernames: Array(data[:detected_external_usernames] || data["detected_external_usernames"]).first(10),
        source_profile_references: Array(data[:source_profile_references] || data["source_profile_references"]).first(10),
        share_status: data[:share_status] || data["share_status"]
      }
    end

    def compact_generation_policy(payload)
      data = payload.is_a?(Hash) ? payload : {}
      allow_comment_value = if data.key?(:allow_comment)
        data[:allow_comment]
      else
        data["allow_comment"]
      end
      {
        allow_comment: ActiveModel::Type::Boolean.new.cast(allow_comment_value),
        reason_code: data[:reason_code] || data["reason_code"],
        reason: truncate_text(data[:reason] || data["reason"], max: 220),
        classification: data[:classification] || data["classification"],
        signal_score: (data[:signal_score] || data["signal_score"]).to_i,
        historical_overlap: ActiveModel::Type::Boolean.new.cast(data[:historical_overlap] || data["historical_overlap"])
      }
    end

    def compact_profile_preparation(payload)
      data = payload.is_a?(Hash) ? payload : {}
      identity = data[:identity_consistency].is_a?(Hash) ? data[:identity_consistency] : (data["identity_consistency"].is_a?(Hash) ? data["identity_consistency"] : {})
      analysis = data[:analysis].is_a?(Hash) ? data[:analysis] : (data["analysis"].is_a?(Hash) ? data["analysis"] : {})

      {
        ready_for_comment_generation: ActiveModel::Type::Boolean.new.cast(data[:ready_for_comment_generation] || data["ready_for_comment_generation"]),
        reason_code: data[:reason_code] || data["reason_code"],
        reason: truncate_text(data[:reason] || data["reason"], max: 220),
        prepared_at: data[:prepared_at] || data["prepared_at"],
        analyzed_posts_count: (analysis[:analyzed_posts_count] || analysis["analyzed_posts_count"]).to_i,
        posts_with_structured_signals_count: (analysis[:posts_with_structured_signals_count] || analysis["posts_with_structured_signals_count"]).to_i,
        latest_posts_analyzed: ActiveModel::Type::Boolean.new.cast(analysis[:latest_posts_analyzed] || analysis["latest_posts_analyzed"]),
        identity_consistency: {
          consistent: ActiveModel::Type::Boolean.new.cast(identity[:consistent] || identity["consistent"]),
          reason_code: identity[:reason_code] || identity["reason_code"],
          dominance_ratio: (identity[:dominance_ratio] || identity["dominance_ratio"]).to_f,
          appearance_count: (identity[:appearance_count] || identity["appearance_count"]).to_i,
          total_faces: (identity[:total_faces] || identity["total_faces"]).to_i
        }
      }
    end

    def compact_minimal_profile_preparation(payload)
      data = payload.is_a?(Hash) ? payload : {}
      identity = data[:identity_consistency].is_a?(Hash) ? data[:identity_consistency] : (data["identity_consistency"].is_a?(Hash) ? data["identity_consistency"] : {})

      {
        ready_for_comment_generation: ActiveModel::Type::Boolean.new.cast(data[:ready_for_comment_generation] || data["ready_for_comment_generation"]),
        reason_code: data[:reason_code] || data["reason_code"],
        reason: truncate_text(data[:reason] || data["reason"], max: 140),
        identity_consistency: {
          consistent: ActiveModel::Type::Boolean.new.cast(identity[:consistent] || identity["consistent"]),
          reason_code: identity[:reason_code] || identity["reason_code"]
        }.compact
      }.compact
    end

    def compact_verified_profile_history(rows)
      Array(rows).first(4).map do |row|
        data = row.is_a?(Hash) ? row : {}
        {
          shortcode: data[:shortcode] || data["shortcode"],
          taken_at: data[:taken_at] || data["taken_at"],
          topics: Array(data[:topics] || data["topics"]).first(4),
          objects: Array(data[:objects] || data["objects"]).first(4),
          hashtags: Array(data[:hashtags] || data["hashtags"]).first(4),
          mentions: Array(data[:mentions] || data["mentions"]).first(4),
          face_count: (data[:face_count] || data["face_count"]).to_i,
          primary_face_count: (data[:primary_face_count] || data["primary_face_count"]).to_i,
          secondary_face_count: (data[:secondary_face_count] || data["secondary_face_count"]).to_i,
          image_description: truncate_text(data[:image_description] || data["image_description"], max: 120)
        }
      end
    end

    def compact_conversational_voice(payload)
      data = payload.is_a?(Hash) ? payload : {}
      conversation_state = data[:conversation_state].is_a?(Hash) ? data[:conversation_state] : (data["conversation_state"].is_a?(Hash) ? data["conversation_state"] : {})
      {
        author_type: data[:author_type] || data["author_type"],
        profile_tags: Array(data[:profile_tags] || data["profile_tags"]).first(6),
        bio_keywords: Array(data[:bio_keywords] || data["bio_keywords"]).first(6),
        recurring_topics: Array(data[:recurring_topics] || data["recurring_topics"]).first(8),
        recurring_hashtags: Array(data[:recurring_hashtags] || data["recurring_hashtags"]).first(6),
        frequent_people_labels: Array(data[:frequent_people_labels] || data["frequent_people_labels"]).first(4),
        prior_comment_examples: Array(data[:prior_comment_examples] || data["prior_comment_examples"]).map { |value| truncate_text(value, max: 80) }.first(3),
        suggested_openers: Array(data[:suggested_openers] || data["suggested_openers"]).map { |value| truncate_text(value, max: 64) }.first(4),
        recent_incoming_messages: Array(data[:recent_incoming_messages] || data["recent_incoming_messages"]).map do |row|
          next unless row.is_a?(Hash)

          {
            body: truncate_text(row[:body] || row["body"], max: 120),
            created_at: row[:created_at] || row["created_at"]
          }
        end.compact.first(2),
        conversation_state: {
          dm_allowed: ActiveModel::Type::Boolean.new.cast(conversation_state[:dm_allowed] || conversation_state["dm_allowed"]),
          has_incoming_messages: ActiveModel::Type::Boolean.new.cast(conversation_state[:has_incoming_messages] || conversation_state["has_incoming_messages"]),
          can_respond_to_existing_messages: ActiveModel::Type::Boolean.new.cast(conversation_state[:can_respond_to_existing_messages] || conversation_state["can_respond_to_existing_messages"]),
          outgoing_message_count: (conversation_state[:outgoing_message_count] || conversation_state["outgoing_message_count"]).to_i
        }
      }.compact
    end

    def compact_minimal_conversational_voice(payload)
      data = payload.is_a?(Hash) ? payload : {}
      conversation_state = data[:conversation_state].is_a?(Hash) ? data[:conversation_state] : (data["conversation_state"].is_a?(Hash) ? data["conversation_state"] : {})

      {
        author_type: data[:author_type] || data["author_type"],
        recurring_topics: Array(data[:recurring_topics] || data["recurring_topics"]).first(3),
        suggested_openers: Array(data[:suggested_openers] || data["suggested_openers"]).map { |value| truncate_text(value, max: 52) }.first(2),
        recent_incoming_messages: Array(data[:recent_incoming_messages] || data["recent_incoming_messages"]).map do |row|
          next unless row.is_a?(Hash)

          { body: truncate_text(row[:body] || row["body"], max: 70) }
        end.compact.first(1),
        conversation_state: {
          has_incoming_messages: ActiveModel::Type::Boolean.new.cast(conversation_state[:has_incoming_messages] || conversation_state["has_incoming_messages"]),
          can_respond_to_existing_messages: ActiveModel::Type::Boolean.new.cast(conversation_state[:can_respond_to_existing_messages] || conversation_state["can_respond_to_existing_messages"])
        }.compact
      }.compact
    end

    def compact_scored_context(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        prioritized_signals: Array(data[:prioritized_signals] || data["prioritized_signals"]).first(6).map do |row|
          next unless row.is_a?(Hash)

          {
            value: truncate_text((row[:value] || row["value"]).to_s, max: 56),
            signal_type: (row[:signal_type] || row["signal_type"]).to_s,
            source: (row[:source] || row["source"]).to_s,
            score: (row[:score] || row["score"]).to_f.round(3)
          }
        end.compact,
        style_profile: compact_style_profile(data[:style_profile] || data["style_profile"]),
        engagement_memory: compact_engagement_memory(data[:engagement_memory] || data["engagement_memory"]),
        context_keywords: Array(data[:context_keywords] || data["context_keywords"]).map(&:to_s).reject(&:blank?).first(14)
      }
    end

    def compact_style_profile(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        tone: data[:tone] || data["tone"],
        formality: data[:formality] || data["formality"],
        punctuation_style: data[:punctuation_style] || data["punctuation_style"],
        emoji_usage: data[:emoji_usage] || data["emoji_usage"],
        avg_comment_length: data[:avg_comment_length] || data["avg_comment_length"]
      }.compact
    end

    def compact_engagement_memory(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        relationship_familiarity: data[:relationship_familiarity] || data["relationship_familiarity"],
        recent_openers: Array(data[:recent_openers] || data["recent_openers"]).map { |value| truncate_text(value, max: 42) }.first(6),
        recent_generated_comments: Array(data[:recent_generated_comments] || data["recent_generated_comments"]).map { |value| truncate_text(value, max: 84) }.first(3),
        recent_story_generated_comments: Array(data[:recent_story_generated_comments] || data["recent_story_generated_comments"]).map { |value| truncate_text(value, max: 84) }.first(3),
        recurring_phrases: Array(data[:common_comment_phrases] || data["common_comment_phrases"]).map { |value| truncate_text(value, max: 40) }.first(6)
      }.compact
    end

    def compact_historical_story_context(rows)
      cutoff = 45.days.ago
      Array(rows).first(8).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        occurred_at = parse_time(data[:occurred_at] || data["occurred_at"])
        next if occurred_at && occurred_at < cutoff

        {
          occurred_at: occurred_at&.iso8601,
          topics: Array(data[:topics] || data["topics"]).first(4),
          objects: Array(data[:objects] || data["objects"]).first(4),
          hashtags: Array(data[:hashtags] || data["hashtags"]).first(4),
          mentions: Array(data[:mentions] || data["mentions"]).first(4),
          profile_handles: Array(data[:profile_handles] || data["profile_handles"]).first(4),
          recurring_people_ids: Array(data[:people] || data["people"]).map { |person| person.is_a?(Hash) ? (person[:person_id] || person["person_id"]) : nil }.compact.first(3),
          face_count: (data[:face_count] || data["face_count"]).to_i
        }
      end.first(4)
    end

    def compact_author_profile(payload, author_type:)
      data = payload.is_a?(Hash) ? payload : {}
      {
        username: data[:username] || data["username"],
        display_name: truncate_text(data[:display_name] || data["display_name"], max: 80),
        author_type: author_type.to_s.presence || "unknown",
        bio_keywords: Array(data[:bio_keywords] || data["bio_keywords"]).map(&:to_s).reject(&:blank?).first(10)
      }
    end

    def compact_identity_verification(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        owner_likelihood: data[:owner_likelihood] || data["owner_likelihood"],
        confidence: (data[:confidence] || data["confidence"]).to_f,
        primary_person_present: ActiveModel::Type::Boolean.new.cast(data[:primary_person_present] || data["primary_person_present"]),
        recurring_primary_person: ActiveModel::Type::Boolean.new.cast(data[:recurring_primary_person] || data["recurring_primary_person"]),
        bio_topic_overlap: Array(data[:bio_topic_overlap] || data["bio_topic_overlap"]).first(8),
        age_consistency: data[:age_consistency] || data["age_consistency"],
        gender_consistency: data[:gender_consistency] || data["gender_consistency"],
        reason_codes: Array(data[:reason_codes] || data["reason_codes"]).first(10)
      }
    end

    def compact_faces_payload(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        total_count: data[:total_count] || data["total_count"],
        primary_user_count: data[:primary_user_count] || data["primary_user_count"],
        secondary_person_count: data[:secondary_person_count] || data["secondary_person_count"],
        unknown_count: data[:unknown_count] || data["unknown_count"],
        people: Array(data[:people] || data["people"]).map do |row|
          r = row.is_a?(Hash) ? row : {}
          {
            person_id: r[:person_id] || r["person_id"],
            role: r[:role] || r["role"],
            label: r[:label] || r["label"],
            similarity: (r[:similarity] || r["similarity"]).to_f.round(3)
          }.compact
        end.first(4)
      }
    end

    def compact_object_detections(rows)
      Array(rows).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        label = (data[:label] || data["label"]).to_s.strip
        next if label.blank?

        {
          label: label.downcase,
          confidence: (data[:confidence] || data["confidence"] || data[:score] || data["score"]).to_f.round(3)
        }
      end.uniq.first(6)
    end

    def compact_scenes(rows)
      Array(rows).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        scene_type = (data[:type] || data["type"]).to_s.strip
        next if scene_type.blank?

        {
          type: scene_type.downcase,
          timestamp: (data[:timestamp] || data["timestamp"]).to_f.round(2)
        }
      end.uniq.first(5)
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def daypart_for(timestamp)
      hour = timestamp.hour
      return "morning" if hour < 12
      return "afternoon" if hour < 17
      return "evening" if hour < 21

      "night"
    end

    def tone_bucket(text)
      body = text.to_s.downcase
      return "curious" if body.include?("?")
      return "celebratory" if body.match?(/\b(congrats|celebrate|huge|big win|so proud)\b/)
      return "playful" if body.match?(/\b(low-key|fr|vibe|mood|iconic)\b/)
      return "supportive" if body.match?(/\b(love|solid|great|nice|clean)\b/)

      "observational"
    end

    def opening_signature(comment)
      comment.to_s.downcase.scan(/[a-z0-9]+/).first(3).join(" ")
    end

    def too_similar_to_selected?(candidate, selected)
      tokens = candidate.to_s.downcase.scan(/[a-z0-9]+/).uniq
      return false if tokens.empty?

      Array(selected).any? do |row|
        compare = row.to_s.downcase.scan(/[a-z0-9]+/).uniq
        next false if compare.empty?

        intersection = (tokens & compare).length
        union = (tokens | compare).length
        next false if union.zero?

        (intersection.to_f / union.to_f) >= 0.74
      end
    end

    def build_light_question(topics:, image_description:, channel:)
      topic_anchors = Array(topics).map { |value| normalize_anchor(value) }.compact
      anchor = topic_anchors.find { |value| !generic_object_anchor?(value) } || topic_anchors.first || extract_keywords_from_text(image_description.to_s).first
      return nil if anchor.blank?

      if Ai::CommentToneProfile.normalize(channel) == "story"
        "What's the story behind this #{anchor} moment?"
      else
        "What inspired this #{anchor} vibe?"
      end
    end

    def build_visual_anchors(image_description:, topics:, verified_story_facts:, scored_context:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      prioritized_detections = prioritized_object_anchor_labels(facts)
      suppress_generic_object_tokens = prioritized_detections.any? { |label| !generic_object_anchor?(label) }
      media_anchors = []
      media_anchors.concat(prioritized_detections)
      media_anchors.concat(filter_anchor_values(Array(topics), suppress_generic_object_tokens: suppress_generic_object_tokens))
      media_anchors.concat(filter_anchor_values(Array(facts[:topics] || facts["topics"]), suppress_generic_object_tokens: suppress_generic_object_tokens))
      media_anchors.concat(filter_anchor_values(Array(facts[:objects] || facts["objects"]), suppress_generic_object_tokens: suppress_generic_object_tokens))
      media_anchors.concat(Array(facts[:hashtags] || facts["hashtags"]).map(&:to_s))
      media_anchors.concat(Array(facts[:mentions] || facts["mentions"]).map(&:to_s))
      media_anchors.concat(Array(facts[:profile_handles] || facts["profile_handles"]).map(&:to_s))
      media_anchors.concat(filter_anchor_values(
        extract_keywords_from_text(image_description.to_s),
        suppress_generic_object_tokens: suppress_generic_object_tokens
      ))
      media_anchors = media_anchors
        .map { |value| normalize_anchor(value) }
        .reject(&:blank?)
        .uniq
      media_anchor_tokens = media_anchors.flat_map { |value| tokenize_text(value) }.uniq

      anchors = media_anchors.dup
      if anchors.size < MIN_MEDIA_ANCHORS_BEFORE_CONTEXT_BLEND
        anchors.concat(
          filter_anchor_values(
            contextual_scored_context_anchor_values(
              scored_context: scored_context,
              media_anchor_tokens: media_anchor_tokens
            ),
            suppress_generic_object_tokens: suppress_generic_object_tokens
          )
        )
      end

      anchors
        .map { |value| normalize_anchor(value) }
        .reject(&:blank?)
        .uniq
        .first(18)
    end

    def contextual_scored_context_anchor_values(scored_context:, media_anchor_tokens:)
      rows = Array(scored_context[:prioritized_signals] || scored_context["prioritized_signals"])
      rows.filter_map do |row|
        next unless row.is_a?(Hash)

        value = (row[:value] || row["value"]).to_s
        source = (row[:source] || row["source"]).to_s.downcase
        overlap_tokens = (row[:overlap_tokens] || row["overlap_tokens"]).to_i
        anchor = normalize_anchor(value)
        next if anchor.blank?
        # Historical profile-store signals can dominate; keep them only when they overlap current media.
        next if source == "store" && overlap_tokens <= 0

        anchor_tokens = tokenize_text(anchor)
        if media_anchor_tokens.any? && source == "store"
          next if (anchor_tokens & media_anchor_tokens).empty?
        end
        anchor
      end
    rescue StandardError
      []
    end

    def build_prompt_input_summary(topics:, visual_anchors:, image_description:, verified_story_facts:, scored_context:, situational_cues:, content_mode:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      keyword_pool = []
      keyword_pool.concat(Array(topics))
      keyword_pool.concat(Array(visual_anchors))
      keyword_pool.concat(Array(facts[:topics] || facts["topics"]))
      keyword_pool.concat(Array(facts[:objects] || facts["objects"]))
      keyword_pool.concat(Array(facts[:hashtags] || facts["hashtags"]))
      keyword_pool.concat(Array(facts[:mentions] || facts["mentions"]))
      keyword_pool.concat(contextual_scored_context_anchor_values(scored_context: scored_context, media_anchor_tokens: []))
      keyword_pool.concat(extract_keywords_from_text(image_description.to_s))

      {
        selected_topics: Array(topics).map { |value| normalize_anchor(value) }.compact.uniq.first(12),
        visual_anchors: Array(visual_anchors).map { |value| normalize_anchor(value) }.compact.uniq.first(12),
        context_keywords: keyword_pool
          .flat_map { |value| tokenize_text(value) }
          .reject { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }
          .uniq
          .first(18),
        situational_cues: Array(situational_cues).map(&:to_s).reject(&:blank?).first(6),
        content_mode: content_mode.to_s.presence || "general"
      }.compact
    rescue StandardError
      {}
    end

    def prioritized_object_anchor_labels(facts)
      rows = Array(facts[:object_detections] || facts["object_detections"]).filter_map do |row|
        next unless row.is_a?(Hash)
        label = normalize_anchor(row[:label] || row["label"])
        next if label.blank?
        confidence = (row[:confidence] || row["confidence"] || row[:score] || row["score"]).to_f.clamp(0.0, 1.0)
        next if confidence < MIN_DETECTION_ANCHOR_CONFIDENCE

        { label: label, confidence: confidence }
      end
      return [] if rows.empty?

      rows.sort_by! { |row| -row[:confidence] }
      strong_specific_detected = rows.any? do |row|
        row[:confidence] >= STRONG_DETECTION_ANCHOR_CONFIDENCE && !generic_object_anchor?(row[:label])
      end

      rows
        .filter_map do |row|
          next if strong_specific_detected && generic_object_anchor?(row[:label])
          next if generic_object_anchor?(row[:label]) && row[:confidence] < STRONG_DETECTION_ANCHOR_CONFIDENCE

          row[:label]
        end
        .uniq
        .first(10)
    end

    def filter_anchor_values(values, suppress_generic_object_tokens:)
      Array(values).filter_map do |value|
        anchor = normalize_anchor(value)
        next if anchor.blank?
        next if suppress_generic_object_tokens && generic_object_anchor?(anchor)

        anchor
      end
    end

    def classify_story_content_mode(image_description:, topics:, verified_story_facts:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      corpus_tokens = story_corpus_tokens(image_description: image_description, topics: topics, verified_story_facts: facts)
      ocr_text = (facts[:ocr_text] || facts["ocr_text"]).to_s
      ocr_tokens = tokenize_text(ocr_text)
      face_count = extract_face_count(facts)

      return "text_heavy" if text_heavy_story?(ocr_text: ocr_text, ocr_tokens: ocr_tokens, corpus_tokens: corpus_tokens)
      return "sports" if overlap_count(corpus_tokens, STORY_MODE_HINTS["sports"]) >= 2
      return "food" if overlap_count(corpus_tokens, STORY_MODE_HINTS["food"]) >= 2
      return "repost_meme" if overlap_count(corpus_tokens, STORY_MODE_HINTS["repost_meme"]) >= 2
      return "group" if face_count >= 3 || overlap_count(corpus_tokens, STORY_MODE_HINTS["group"]) >= 2
      return "portrait" if face_count.positive? || corpus_tokens.include?("portrait") || corpus_tokens.include?("selfie")

      "general"
    end

    def select_fallback_anchor(anchors:, mode:, image_description:, verified_story_facts:)
      specific_anchor = Array(anchors).find { |value| !generic_object_anchor?(value) }
      return specific_anchor if specific_anchor.present?

      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      ocr_tokens = tokenize_text((facts[:ocr_text] || facts["ocr_text"]).to_s)
      ocr_anchor = ocr_tokens.reject { |token| token.length < 4 }.first(3).join(" ")
      return ocr_anchor if mode == "text_heavy" && ocr_anchor.present?

      case mode
      when "sports" then "match moment"
      when "group" then "group moment"
      when "food" then "food moment"
      when "portrait" then "portrait"
      when "repost_meme" then "story mood"
      when "text_heavy" then "message"
      else
        normalize_anchor(extract_keywords_from_text(image_description.to_s).first) || "moment"
      end
    end

    def text_heavy_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "message"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "Your #{base} is super clear right away, easy to follow 📌",
          "Text-first but still feels natural, nice flow.",
          "The message in this one lands quick ⚡",
          "This #{base} feels intentional without trying too hard.",
          "Really solid text + visual balance here.",
          "What made you go with this #{base} angle?",
          "The wording feels relatable and direct.",
          "This one gets the point across fast 💯"
        ]
      else
        [
          "That #{base} is clear right away and easy to read 📌",
          "Text-forward, but still feels human and natural.",
          "The message lands quickly in this one ⚡",
          "This #{base} angle feels intentional.",
          "Nice text and visual balance here.",
          "What message did you want people to feel first?",
          "Straight to the point in a good way.",
          "This one keeps the message clear without overdoing it."
        ]
      end
    end

    def sports_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "action moment"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "Your #{base} moment goes hard, love the energy ⚽",
          "The timing here is actually so good.",
          "You can feel the game-day rush in this one 🔥",
          "This #{base} has big momentum.",
          "Such a fun sports moment to catch.",
          "What part of the match had everyone loud?",
          "The intensity in this one is real.",
          "Okay this #{base} was clean 👏"
        ]
      else
        [
          "That #{base} timing is elite ⚽",
          "Big sports energy in this one.",
          "The pace of this moment really comes through 🔥",
          "This #{base} feels super alive.",
          "Love how intense this looks.",
          "Which part of the game was this from?",
          "Such a strong sports update.",
          "That #{base} capture hits."
        ]
      end
    end

    def group_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "group moment"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "This #{base} feels wholesome, you all look locked in 🫶",
          "Such a good group moment.",
          "The energy in your crew feels genuine.",
          "This one feels like core memory material.",
          "Group vibes are super warm here ✨",
          "Where did this #{base} happen?",
          "You all look naturally in the moment.",
          "This group pic hits different ❤️"
        ]
      else
        [
          "This #{base} has great group energy 🫶",
          "Everyone looks genuinely happy here.",
          "Such a natural group moment.",
          "The vibe across everyone feels real.",
          "This one feels like a memory keeper.",
          "What was the occasion behind this #{base}?",
          "Strong group update, really fun.",
          "Everyone being in sync makes this one stand out."
        ]
      end
    end

    def food_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "food moment"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "This #{base} looks unreal, now I'm hungry 😮‍💨",
          "The colors on this are so satisfying.",
          "Love how the #{base} is presented.",
          "This meal moment feels cozy.",
          "Your #{base} has major comfort-food energy 🍜",
          "What was your favorite bite from this #{base}?",
          "This food update feels super inviting.",
          "The #{base} here is making me want a repeat."
        ]
      else
        [
          "This #{base} looks so good 😮‍💨",
          "The colors and plating are really satisfying.",
          "Love this kind of #{base} update.",
          "This meal moment feels cozy and real.",
          "That #{base} has serious comfort-food energy 🍜",
          "What dish are we looking at here?",
          "Super appetizing post.",
          "The #{base} here totally works."
        ]
      end
    end

    def portrait_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "portrait"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "This #{base} look lands really well ✨",
          "The styling here feels effortless.",
          "Great energy in this #{base}.",
          "This one feels confident and natural.",
          "The expression in this #{base} is so good 🙂",
          "What inspired this #{base} look?",
          "This has that low-key iconic feel.",
          "Such a strong #{base} moment."
        ]
      else
        [
          "This #{base} look really works ✨",
          "Styling here feels effortless.",
          "Great energy in this #{base}.",
          "This one feels confident and natural.",
          "Expression and vibe both land 🙂",
          "What was the idea behind this #{base} look?",
          "Low-key iconic #{base} moment.",
          "This portrait update stands out."
        ]
      end
    end

    def repost_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "story mood"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "This repost mood is relatable fr 😌",
          "Your #{base} comes through immediately.",
          "Text + visual combo feels intentional.",
          "This one carries a real feeling.",
          "The tone here is easy to connect with.",
          "What made this #{base} worth sharing?",
          "This repost has a thoughtful vibe.",
          "Mood is clear and it works 💭"
        ]
      else
        [
          "This repost mood is relatable 😌",
          "The #{base} comes through quickly.",
          "Message and visual tone match well.",
          "This one carries a clear feeling.",
          "Easy to connect with this share.",
          "What drew you to share this #{base}?",
          "Thoughtful repost choice.",
          "The mood here is clear and authentic."
        ]
      end
    end

    def generic_fallback_comments(anchor:, channel:)
      base = anchor.to_s.presence || "moment"
      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "This #{base} moment feels super genuine ✨",
          "Love this #{base} energy.",
          "The way this comes together feels natural.",
          "This #{base} has a nice personal touch.",
          "Such an easy one to connect with 🙂",
          "What made this #{base} moment the one to share?",
          "The mood here feels warm and real.",
          "This #{base} stands out in a good way."
        ]
      else
        [
          "This #{base} moment feels genuine ✨",
          "Really like this #{base} energy.",
          "This one feels natural and easy to connect with.",
          "The #{base} adds a relatable touch.",
          "Solid share with a good vibe 🙂",
          "What inspired this #{base} moment?",
          "The mood here feels real.",
          "This #{base} stands out in a good way."
        ]
      end
    end

    def text_heavy_story?(ocr_text:, ocr_tokens:, corpus_tokens:)
      has_layout_keywords = overlap_count(corpus_tokens, STORY_MODE_HINTS["text_heavy"]) >= 2
      has_percentage_or_rate = ocr_text.to_s.match?(/\b\d{1,3}(?:\.\d+)?%|\bapr\b|\brate\b/i)
      ocr_tokens.length >= 6 || has_layout_keywords || has_percentage_or_rate
    end

    def story_corpus_tokens(image_description:, topics:, verified_story_facts:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      tokens = []
      tokens.concat(tokenize_text(image_description))
      tokens.concat(Array(topics).flat_map { |row| tokenize_text(row) })
      tokens.concat(Array(facts[:topics] || facts["topics"]).flat_map { |row| tokenize_text(row) })
      tokens.concat(Array(facts[:objects] || facts["objects"]).flat_map { |row| tokenize_text(row) })
      tokens.concat(Array(facts[:hashtags] || facts["hashtags"]).flat_map { |row| tokenize_text(row) })
      tokens.concat(Array(facts[:mentions] || facts["mentions"]).flat_map { |row| tokenize_text(row) })
      tokens.concat(
        Array(facts[:scenes] || facts["scenes"]).flat_map do |row|
          row.is_a?(Hash) ? tokenize_text(row[:type] || row["type"]) : tokenize_text(row)
        end
      )
      tokens.concat(tokenize_text(facts[:ocr_text] || facts["ocr_text"]))
      tokens.uniq
    end

    def extract_face_count(verified_story_facts)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      count = (facts[:face_count] || facts["face_count"]).to_i
      return count if count.positive?

      faces = facts[:faces].is_a?(Hash) ? facts[:faces] : (facts["faces"].is_a?(Hash) ? facts["faces"] : {})
      (faces[:total_count] || faces["total_count"]).to_i
    end

    def overlap_count(tokens, hint_tokens)
      token_rows = Array(tokens).map(&:to_s)
      hints = Array(hint_tokens).map(&:to_s)
      (token_rows & hints).size
    end

    def tokenize_text(value)
      value.to_s.downcase.scan(/[a-z0-9_]+/).reject { |token| token.length < 3 }.uniq
    end

    def generic_object_anchor?(value)
      tokens = value.to_s.downcase.scan(/[a-z0-9_]+/)
      return false if tokens.empty?

      tokens.all? { |token| GENERIC_OBJECT_ANCHORS.include?(token) }
    end

    def normalize_anchor(value)
      text = value.to_s.downcase.strip
      return nil if text.blank?

      cleaned = text.gsub(/[^a-z0-9#@_\-\s]/, " ").gsub(/\s+/, " ").strip
      return nil if cleaned.blank?

      tokens = cleaned.scan(/[a-z0-9#@_\-]+/)
      return nil if tokens.empty?
      return nil if tokens.all? { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }

      tokens.join(" ").byteslice(0, 36)
    end
  end
end
