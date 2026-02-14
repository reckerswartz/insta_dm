module Ai
  module Providers
    class AzureVisionProvider < BaseProvider
      def key
        "azure_vision"
      end

      def supports_profile?
        true
      end

      def supports_post_image?
        true
      end

      def supports_post_video?
        false
      end

      def available?
        super && effective_endpoint.present?
      end

      def test_key!
        client.test_key!
      rescue StandardError => e
        { ok: false, message: e.message.to_s }
      end

      def analyze_profile!(profile_payload:, media: nil)
        tags = []
        captions = []

        Array(media).each do |item|
          next unless item.is_a?(Hash)

          response = analyze_media_item(item)
          tags.concat(extract_tags(response))
          captions << response.dig("captionResult", "text").to_s.strip
        rescue StandardError
          next
        end

        text = [ profile_payload[:bio].to_s, Array(profile_payload[:recent_outgoing_messages]).map { |m| m[:body] }.join(" ") ].join(" ").downcase
        location = if text.match?(/\b(hindi|india|indian)\b/)
          "India"
        elsif text.match?(/\b(english|usa|us)\b/)
          "United States"
        else
          "unknown"
        end

        {
          model: "azure-image-analysis+rules",
          prompt: { provider: key, media_count: Array(media).size, rule_based: true },
          response_text: "azure_rule_based_profile_analysis",
          response_raw: { tags: tags, captions: captions },
          analysis: {
            "summary" => captions.compact_blank.first.presence || "Rule-based Azure Vision profile analysis.",
            "languages" => [ { language: "english", confidence: 0.6 } ],
            "likes" => tags.first(10),
            "dislikes" => [],
            "intent_labels" => [ "unknown" ],
            "writing_style" => {
              "tone" => "friendly",
              "formality" => "casual",
              "emoji_usage" => text.match?(/[^\x00-\x7F]/) ? "present" : "low",
              "slang_level" => "low"
            },
            "demographic_estimates" => {
              "age" => 26,
              "age_confidence" => 0.25,
              "gender" => "unknown",
              "gender_confidence" => 0.2,
              "location" => location,
              "location_confidence" => location == "unknown" ? 0.1 : 0.3
            },
            "self_declared" => { "age" => nil, "gender" => nil, "location" => nil, "pronouns" => nil, "other" => nil },
            "suggested_dm_openers" => [
              "Your content is super clean, what are you shooting with lately?",
              "Okay this profile aesthetic is on point, what inspired it?"
            ],
            "suggested_comment_templates" => [
              "This is a whole vibe 🔥",
              "So clean, love this shot 👏"
            ],
            "confidence_notes" => "Generated from Azure Vision tags/captions + profile text."
          }
        }
      end

      def analyze_post!(post_payload:, media: nil)
        media_hash = media.is_a?(Hash) ? media : {}
        response = analyze_media_item(media_hash)
        tags = extract_tags(response)
        caption = response.dig("captionResult", "text").to_s.strip
        image_description = caption.presence || (tags.any? ? "Image appears to include #{tags.first(4).join(', ')}." : "No clear visual labels detected.")

        {
          model: "azure-image-analysis+rules",
          prompt: { provider: key, media_type: media_hash[:type].to_s, rule_based: true },
          response_text: "azure_rule_based_post_analysis",
          response_raw: response,
          analysis: {
            "image_description" => image_description,
            "relevant" => tags.any?,
            "author_type" => infer_author_type(post_payload),
            "topics" => tags.first(12),
            "sentiment" => "unknown",
            "suggested_actions" => [ "review", "comment_suggestion" ],
            "recommended_next_action" => "review",
            "engagement_score" => tags.any? ? 0.58 : 0.4,
            "comment_suggestions" => build_comment_suggestions(tags: tags),
            "personalization_tokens" => tags.first(5),
            "confidence" => tags.any? ? 0.6 : 0.42,
            "evidence" => tags.any? ? "Azure tags: #{tags.first(5).join(', ')}" : "No tags detected"
          }
        }
      end

      private

      def client
        @client ||= Ai::AzureVisionClient.new(
          api_key: ensure_api_key!,
          endpoint: effective_endpoint,
          api_version: setting&.config_value("api_version").to_s
        )
      end

      def effective_endpoint
        setting&.config_value("endpoint").to_s.presence || Rails.application.credentials.dig(:azure_vision, :endpoint).to_s
      end

      def analyze_media_item(item)
        return {} unless item.is_a?(Hash)
        return {} unless item[:type].to_s == "image"

        if item[:bytes].present?
          client.analyze_image_bytes!(item[:bytes], features: %w[tags caption read])
        elsif item[:url].to_s.start_with?("http://", "https://")
          client.analyze_image_url!(item[:url], features: %w[tags caption read])
        else
          {}
        end
      end

      def extract_tags(response)
        Array(response.dig("tagsResult", "values")).map { |v| v["name"].to_s.downcase.strip }.reject(&:blank?).uniq
      end

      def infer_author_type(post_payload)
        tags = Array(post_payload.dig(:author_profile, :tags)).map(&:to_s)
        return "relative" if tags.include?("relative")
        return "friend" if (tags & %w[friend female_friend male_friend]).any?
        return "page" if tags.include?("page")
        return "personal_user" if tags.include?("personal_user")

        "unknown"
      end

      def build_comment_suggestions(tags:)
        topic = tags.first.presence || "post"
        [
          "This #{topic} shot is low-key fire 🔥",
          "Okay this is such a vibe, love it 👏",
          "Clean capture fr, this goes hard ✨"
        ]
      end
    end
  end
end
