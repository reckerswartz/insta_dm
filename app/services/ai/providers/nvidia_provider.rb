module Ai
  module Providers
    # NVIDIA Build provider. The provider itself is a thin dispatcher;
    # per-call work (chat / vision / embedding) happens in Ai::NvidiaClient
    # routed by role via Ai::NvidiaModelRouter.
    #
    # analyze_profile! uses the text_quality model. analyze_post! uses
    # vision_primary when a post image is present, else text_quality.
    # Both coerce the LLM output into the analysis hash shape expected by
    # Ai::InsightSync so downstream materialisation is identical to the
    # legacy LocalProvider.
    class NvidiaProvider < BaseProvider
      PROFILE_SCHEMA_VERSION = "nvidia.profile.v1".freeze
      POST_SCHEMA_VERSION = "nvidia.post.v1".freeze

      VISION_FRAME_SAMPLE_LIMIT = ENV.fetch("NVIDIA_VISION_MAX_IMAGES", "2").to_i.clamp(1, 6)

      def key
        "nvidia"
      end

      def display_name
        setting&.display_name || "NVIDIA Build"
      end

      def supports_profile?
        true
      end

      def supports_post_image?
        true
      end

      def supports_post_video?
        true
      end

      def requires_api_key?
        true
      end

      # Availability is evaluated across all role rows for this provider:
      # at minimum we need an enabled text_quality (or text_fast) with a
      # key present. Vision/embedding roles are checked lazily per call.
      def available?
        return false unless any_text_role_enabled?
        true
      end

      # Lightweight key check using /v1/models on the default role.
      def test_key!
        key_setting = text_setting || any_enabled_setting
        raise "No enabled NVIDIA provider row with an api_key" unless key_setting

        client = Ai::NvidiaClient.new(setting: key_setting)
        result = client.list_models!
        models = result.is_a?(Hash) ? result["data"] : []
        {
          ok: true,
          models_count: Array(models).length,
          role_used: key_setting.role,
          base_url: key_setting.effective_base_url
        }
      end

      # Profile analysis uses the text_quality model with a JSON-structured
      # system prompt. We do NOT feed media for profile analysis (NVIDIA is
      # token-priced and profile pictures add little signal for the
      # text-heavy output schema).
      def analyze_profile!(profile_payload:, media: nil)
        role_setting = Ai::NvidiaModelRouter.resolve!("text_quality")
        messages = build_profile_messages(profile_payload: profile_payload, media: media)

        raw = call_chat!(
          role_setting: role_setting,
          messages: messages,
          temperature: 0.35,
          max_tokens: 1_200,
          response_format: { "type" => "json_object" }
        )

        response_text = raw.dig("choices", 0, "message", "content").to_s
        analysis = coerce_profile_analysis(response_text)

        {
          model: role_setting.effective_model,
          prompt: {
            provider: key,
            role: "text_quality",
            system_prompt_hash: Digest::SHA1.hexdigest(messages.first[:content].to_s),
            schema: PROFILE_SCHEMA_VERSION,
            has_media: Array(media).any?
          },
          response_text: response_text,
          response_raw: raw,
          analysis: analysis
        }
      end

      # Post analysis uses vision_primary when the payload includes image
      # bytes or a data URL, and text_quality otherwise. Videos get
      # frame-sampled to up to VISION_FRAME_SAMPLE_LIMIT keyframes.
      def analyze_post!(post_payload:, media: nil, provider_options: {})
        images = extract_image_data_urls(media)
        if images.any?
          role_setting = Ai::NvidiaModelRouter.resolve!("vision_primary")
          messages = build_post_vision_messages(post_payload: post_payload, image_data_urls: images)
        else
          role_setting = Ai::NvidiaModelRouter.resolve!("text_quality")
          messages = build_post_text_only_messages(post_payload: post_payload)
        end

        raw = call_chat!(
          role_setting: role_setting,
          messages: messages,
          temperature: 0.35,
          max_tokens: 1_400,
          response_format: { "type" => "json_object" }
        )

        response_text = raw.dig("choices", 0, "message", "content").to_s
        analysis = coerce_post_analysis(response_text)

        {
          model: role_setting.effective_model,
          prompt: {
            provider: key,
            role: role_setting.role,
            image_count: images.length,
            schema: POST_SCHEMA_VERSION,
            provider_options: provider_options
          },
          response_text: response_text,
          response_raw: raw,
          analysis: analysis
        }
      end

      # Internal helpers other services can call (comment generation etc).
      def chat!(role:, messages:, **opts)
        row = Ai::NvidiaModelRouter.resolve!(role)
        call_chat!(role_setting: row, messages: messages, **opts)
      end

      def embed!(input:, role: "embedding", **opts)
        row = Ai::NvidiaModelRouter.resolve!(role)
        Ai::NvidiaClient.new(setting: row, rate_limiter: Ai::NvidiaRateLimiter.new)
                        .embed!(model: row.effective_model, input: input, **opts)
      end

      private

      def call_chat!(role_setting:, messages:, **opts)
        Ai::NvidiaClient.new(setting: role_setting, rate_limiter: Ai::NvidiaRateLimiter.new)
                        .chat!(model: role_setting.effective_model, messages: messages, **opts)
      end

      def any_text_role_enabled?
        AiProviderSetting
          .for_provider(key)
          .where(role: %w[text_quality text_fast], enabled: true)
          .any? { |s| s.api_key_present? }
      end

      def text_setting
        Ai::NvidiaModelRouter.resolve("text_quality") ||
          Ai::NvidiaModelRouter.resolve("text_fast")
      end

      def any_enabled_setting
        AiProviderSetting
          .for_provider(key)
          .where(enabled: true)
          .order(priority: :asc)
          .find { |s| s.api_key_present? }
      end

      # ------------ profile prompt / parsing ------------

      def build_profile_messages(profile_payload:, media:)
        bio = profile_payload[:bio].to_s
        full_name = profile_payload[:full_name].to_s
        username = profile_payload[:username].to_s
        post_samples = Array(profile_payload[:recent_post_captions])
                         .map(&:to_s).reject(&:blank?).first(6).map { |c| c.truncate(240) }
        outgoing = Array(profile_payload[:recent_outgoing_messages])
                     .map { |m| m.is_a?(Hash) ? m[:body].to_s : m.to_s }
                     .reject(&:blank?).first(6).map { |c| c.truncate(220) }

        system = <<~SYS.strip
          You are an Instagram-relationship analyst who produces strictly valid JSON conforming to a fixed schema. Never include prose, explanations, or markdown fences -- only a single JSON object.

          Schema keys (all required; use [] or null when you have no evidence):
          {
            "summary": string,
            "languages": [{ "language": string, "confidence": 0..1, "evidence": string }],
            "likes": [string],
            "dislikes": [string],
            "intent_labels": [string],
            "conversation_hooks": [{ "hook": string, "evidence": string }],
            "personalization_tokens": [string],
            "no_go_zones": [string],
            "writing_style": {
              "tone": string,
              "formality": string,
              "emoji_usage": string,
              "slang_level": string,
              "evidence": string
            },
            "response_style_prediction": string,
            "engagement_probability": 0..1,
            "recommended_next_action": "dm" | "comment" | "review" | "skip",
            "demographic_estimates": {
              "age": null | { "low": int, "high": int },
              "age_confidence": 0..1,
              "gender": null | string,
              "gender_confidence": 0..1,
              "location": null | string,
              "location_confidence": 0..1,
              "evidence": string
            },
            "self_declared": {
              "age": null | int,
              "gender": null | string,
              "location": null | string,
              "pronouns": null | string,
              "other": null | string
            },
            "suggested_dm_openers": [string],       // 3-5 items, conversational, under 160 chars each
            "suggested_comment_templates": [string], // 3-5 items, under 120 chars each
            "confidence_notes": string,
            "why_not_confident": string
          }
        SYS

        user = <<~USR.strip
          Profile to analyse:
          username: #{username}
          full_name: #{full_name}
          bio: #{bio.presence || '(empty)'}

          Recent post captions (newest first):
          #{post_samples.empty? ? '(none)' : post_samples.map { |c| "- #{c}" }.join("\n")}

          Recent outgoing messages from the operator (newest first):
          #{outgoing.empty? ? '(none)' : outgoing.map { |m| "- #{m}" }.join("\n")}

          Additional signals:
          can_message: #{profile_payload[:can_message].inspect}
          following: #{profile_payload[:following].inspect}
          follows_you: #{profile_payload[:follows_you].inspect}

          Return ONLY the JSON object described in the schema. Ground every hook, like, and dislike in evidence from the text above. Suggest conversational, friend-to-friend DM openers (Gen Z friendly) and short comment templates.
        USR

        [
          { role: "system", content: system },
          { role: "user", content: user }
        ]
      end

      def coerce_profile_analysis(response_text)
        data = parse_json_blob(response_text) || {}
        {
          "summary" => data["summary"].to_s.presence || "NVIDIA profile analysis",
          "languages" => normalize_languages(data["languages"]),
          "likes" => string_array(data["likes"]).first(20),
          "dislikes" => string_array(data["dislikes"]).first(20),
          "intent_labels" => string_array(data["intent_labels"]).first(10),
          "conversation_hooks" => normalize_hooks(data["conversation_hooks"]).first(8),
          "personalization_tokens" => string_array(data["personalization_tokens"]).first(15),
          "no_go_zones" => string_array(data["no_go_zones"]).first(15),
          "writing_style" => normalize_writing_style(data["writing_style"]),
          "response_style_prediction" => data["response_style_prediction"].to_s.presence || "unknown",
          "engagement_probability" => clamp_unit(data["engagement_probability"], default: 0.5),
          "recommended_next_action" => normalize_action(data["recommended_next_action"]),
          "demographic_estimates" => normalize_demographics(data["demographic_estimates"]),
          "self_declared" => normalize_self_declared(data["self_declared"]),
          "suggested_dm_openers" => string_array(data["suggested_dm_openers"]).first(8),
          "suggested_comment_templates" => string_array(data["suggested_comment_templates"]).first(8),
          "confidence_notes" => data["confidence_notes"].to_s,
          "why_not_confident" => data["why_not_confident"].to_s
        }
      end

      # ------------ post prompt / parsing ------------

      def build_post_vision_messages(post_payload:, image_data_urls:)
        system = post_system_prompt
        parts = [{ type: "text", text: post_user_prompt_body(post_payload: post_payload) }]
        image_data_urls.first(VISION_FRAME_SAMPLE_LIMIT).each do |data_url|
          parts << { type: "image_url", image_url: { url: data_url } }
        end
        [
          { role: "system", content: system },
          { role: "user", content: parts }
        ]
      end

      def build_post_text_only_messages(post_payload:)
        [
          { role: "system", content: post_system_prompt },
          { role: "user", content: post_user_prompt_body(post_payload: post_payload) + "\n\nNo image available: derive analysis from the caption and metadata alone. Set image_description to 'Image unavailable.'" }
        ]
      end

      def post_system_prompt
        <<~SYS.strip
          You are an Instagram content analyst producing strictly valid JSON only. No prose, no markdown, no explanations -- just the JSON object.

          Schema:
          {
            "image_description": string,
            "relevant": boolean,
            "author_type": "creator" | "business" | "personal" | "page" | "unknown",
            "sentiment": "positive" | "neutral" | "negative" | "mixed",
            "topics": [string],                  // up to 10 concrete nouns / themes
            "personalization_tokens": [string],  // up to 10 specific tokens worth referencing
            "suggested_actions": [string],       // e.g. "comment", "dm", "skip"
            "comment_suggestions": [string],     // 3-5, under 120 chars, natural, non-generic
            "confidence": 0..1,
            "engagement_score": 0..1,
            "evidence": string,
            "recommended_next_action": "comment" | "dm" | "skip" | "review"
          }
        SYS
      end

      def post_user_prompt_body(post_payload:)
        caption = post_payload[:caption].to_s.truncate(1200)
        owner = post_payload[:owner_username].to_s
        media_type = post_payload[:media_type].to_s
        taken_at = post_payload[:taken_at].to_s

        <<~USR.strip
          Post to analyse:
          owner: #{owner}
          media_type: #{media_type}
          taken_at: #{taken_at}
          caption: #{caption.presence || '(empty)'}

          Describe the image in one sentence, extract concrete topics, and write 3-5 short comment suggestions that feel like a real follower wrote them. Avoid generic compliments ("Nice!", "Cool post!"). Prefer comments that hook on a specific visible thing or phrase in the caption.

          Return ONLY the JSON object described in the schema.
        USR
      end

      def coerce_post_analysis(response_text)
        data = parse_json_blob(response_text) || {}
        {
          "image_description" => data["image_description"].to_s.presence || "Image unavailable.",
          "relevant" => bool_with_default(data["relevant"], default: true),
          "author_type" => normalize_author_type(data["author_type"]),
          "sentiment" => normalize_sentiment(data["sentiment"]),
          "topics" => string_array(data["topics"]).first(15),
          "personalization_tokens" => string_array(data["personalization_tokens"]).first(15),
          "suggested_actions" => string_array(data["suggested_actions"]).first(6),
          "comment_suggestions" => string_array(data["comment_suggestions"]).first(8),
          "confidence" => clamp_unit(data["confidence"], default: 0.6),
          "engagement_score" => clamp_unit(data["engagement_score"], default: 0.5),
          "evidence" => data["evidence"].to_s,
          "recommended_next_action" => normalize_action(data["recommended_next_action"])
        }
      end

      # ------------ media extraction ------------

      # Accepts the media hash that Ai::Runner hands providers. Returns an
      # array of "data:<mime>;base64,..." strings ready for the VLM
      # messages content block.
      def extract_image_data_urls(media)
        return [] if media.nil?
        return media_hash_to_data_urls(media) if media.is_a?(Hash)

        Array(media).flat_map { |m| media_hash_to_data_urls(m) }.compact
      end

      def media_hash_to_data_urls(media)
        return [] unless media.is_a?(Hash)

        case media[:type].to_s
        when "image"
          bytes = media[:bytes] || media["bytes"]
          return [] if bytes.blank?

          mime = media[:content_type].presence || media["content_type"].presence || "image/jpeg"
          [Ai::NvidiaClient.image_data_url(bytes: bytes, mime_type: mime)]
        when "video"
          Array(media[:frames] || media["frames"]).first(VISION_FRAME_SAMPLE_LIMIT).map do |frame|
            next nil if frame.blank?

            bytes = frame.is_a?(Hash) ? frame[:image_bytes] || frame["image_bytes"] : frame
            mime = frame.is_a?(Hash) ? (frame[:content_type] || frame["content_type"] || "image/jpeg") : "image/jpeg"
            next nil if bytes.blank?

            Ai::NvidiaClient.image_data_url(bytes: bytes, mime_type: mime)
          end.compact
        else
          []
        end
      end

      # ------------ parsing helpers ------------

      def parse_json_blob(text)
        stripped = text.to_s.strip
        # Models sometimes wrap JSON in ```json ... ``` fences despite the
        # system prompt. Strip them defensively.
        stripped = stripped.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
        return nil if stripped.empty?

        JSON.parse(stripped)
      rescue JSON::ParserError
        # Last-resort: try to extract the biggest JSON object substring.
        match = stripped[/\{.*\}/m]
        return nil unless match

        begin
          JSON.parse(match)
        rescue JSON::ParserError
          nil
        end
      end

      def string_array(value)
        Array(value).filter_map { |v| v.to_s.strip.presence }
      end

      def clamp_unit(value, default:)
        f = Float(value) rescue default
        f.clamp(0.0, 1.0)
      end

      def bool_with_default(value, default:)
        return default if value.nil?

        ActiveModel::Type::Boolean.new.cast(value)
      end

      def normalize_languages(value)
        Array(value).filter_map do |item|
          next nil unless item.is_a?(Hash)

          name = item["language"].to_s.strip.presence
          next nil unless name

          {
            "language" => name,
            "confidence" => clamp_unit(item["confidence"], default: 0.6),
            "evidence" => item["evidence"].to_s
          }
        end.first(6)
      end

      def normalize_hooks(value)
        Array(value).filter_map do |item|
          next nil unless item.is_a?(Hash)
          hook = item["hook"].to_s.strip.presence
          next nil unless hook

          { "hook" => hook, "evidence" => item["evidence"].to_s }
        end
      end

      def normalize_writing_style(value)
        h = value.is_a?(Hash) ? value : {}
        {
          "tone" => h["tone"].to_s.presence || "unknown",
          "formality" => h["formality"].to_s.presence || "unknown",
          "emoji_usage" => h["emoji_usage"].to_s.presence || "unknown",
          "slang_level" => h["slang_level"].to_s.presence || "unknown",
          "evidence" => h["evidence"].to_s
        }
      end

      def normalize_demographics(value)
        h = value.is_a?(Hash) ? value : {}
        {
          "age" => h["age"].is_a?(Hash) ? h["age"] : nil,
          "age_confidence" => clamp_unit(h["age_confidence"], default: 0.0),
          "gender" => h["gender"].to_s.presence,
          "gender_confidence" => clamp_unit(h["gender_confidence"], default: 0.0),
          "location" => h["location"].to_s.presence,
          "location_confidence" => clamp_unit(h["location_confidence"], default: 0.0),
          "evidence" => h["evidence"].to_s
        }
      end

      def normalize_self_declared(value)
        h = value.is_a?(Hash) ? value : {}
        {
          "age" => (Integer(h["age"]) rescue nil),
          "gender" => h["gender"].to_s.presence,
          "location" => h["location"].to_s.presence,
          "pronouns" => h["pronouns"].to_s.presence,
          "other" => h["other"].to_s.presence
        }
      end

      def normalize_action(value)
        v = value.to_s.strip.downcase
        %w[dm comment review skip].include?(v) ? v : "review"
      end

      def normalize_author_type(value)
        v = value.to_s.strip.downcase
        %w[creator business personal page unknown].include?(v) ? v : "unknown"
      end

      def normalize_sentiment(value)
        v = value.to_s.strip.downcase
        %w[positive neutral negative mixed].include?(v) ? v : "neutral"
      end
    end
  end
end
