module Ai
  module Providers
    class AwsRekognitionProvider < BaseProvider
      def key
        "aws_rekognition"
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
        super && effective_access_key_id.present? && effective_region.present? && sdk_loaded?
      end

      def test_key!
        return { ok: false, message: "aws-sdk-rekognition gem is not installed" } unless sdk_loaded?

        client.test_key!
      rescue StandardError => e
        { ok: false, message: e.message.to_s }
      end

      def analyze_profile!(profile_payload:, media: nil)
        labels = []
        Array(media).each do |item|
          next unless item.is_a?(Hash)
          next unless item[:type].to_s == "image"
          next if item[:bytes].blank?

          res = client.detect_labels!(bytes: item[:bytes], max_labels: 15)
          labels.concat(extract_labels(res))
        rescue StandardError
          next
        end

        {
          model: "aws-rekognition+rules",
          prompt: { provider: key, media_count: Array(media).size, rule_based: true },
          response_text: "aws_rekognition_rule_based_profile_analysis",
          response_raw: { labels: labels },
          analysis: {
            "summary" => labels.any? ? "Detected profile themes from media labels." : "No clear visual labels detected.",
            "languages" => [ { language: "english", confidence: 0.55 } ],
            "likes" => labels.first(10),
            "dislikes" => [],
            "intent_labels" => [ "unknown" ],
            "writing_style" => {
              "tone" => "friendly",
              "formality" => "casual",
              "emoji_usage" => "low",
              "slang_level" => "low"
            },
            "demographic_estimates" => {
              "age" => 26,
              "age_confidence" => 0.2,
              "gender" => "unknown",
              "gender_confidence" => 0.2,
              "location" => "unknown",
              "location_confidence" => 0.1
            },
            "self_declared" => { "age" => nil, "gender" => nil, "location" => nil, "pronouns" => nil, "other" => nil },
            "suggested_dm_openers" => [
              "Your content theme is super consistent, what are you focusing on lately?",
              "Really like your style here, what got you into this?"
            ],
            "suggested_comment_templates" => [
              "This looks so clean 🔥",
              "Love the mood on this one 👏"
            ],
            "confidence_notes" => "Generated from AWS Rekognition labels and lightweight rules."
          }
        }
      end

      def analyze_post!(post_payload:, media: nil)
        media_hash = media.is_a?(Hash) ? media : {}
        labels = []
        if media_hash[:type].to_s == "image" && media_hash[:bytes].present?
          response = client.detect_labels!(bytes: media_hash[:bytes], max_labels: 20)
          labels = extract_labels(response)
        end
        description = labels.any? ? "Image likely contains #{labels.first(4).join(', ')}." : "No strong labels detected."

        {
          model: "aws-rekognition+rules",
          prompt: { provider: key, media_type: media_hash[:type].to_s, rule_based: true },
          response_text: "aws_rekognition_rule_based_post_analysis",
          response_raw: { labels: labels },
          analysis: {
            "image_description" => description,
            "relevant" => labels.any?,
            "author_type" => infer_author_type(post_payload),
            "topics" => labels.first(12),
            "sentiment" => "unknown",
            "suggested_actions" => [ "review", "comment_suggestion" ],
            "recommended_next_action" => "review",
            "engagement_score" => labels.any? ? 0.56 : 0.4,
            "comment_suggestions" => build_comment_suggestions(labels: labels),
            "personalization_tokens" => labels.first(5),
            "confidence" => labels.any? ? 0.58 : 0.4,
            "evidence" => labels.any? ? "AWS labels: #{labels.first(5).join(', ')}" : "No labels"
          }
        }
      end

      private

      def sdk_loaded?
        defined?(Aws::Rekognition::Client)
      end

      def client
        @client ||= Ai::AwsRekognitionClient.new(
          access_key_id: effective_access_key_id,
          secret_access_key: ensure_api_key!,
          region: effective_region
        )
      end

      def effective_access_key_id
        setting&.config_value("access_key_id").to_s.presence || Rails.application.credentials.dig(:aws, :access_key_id).to_s
      end

      def effective_region
        setting&.config_value("region").to_s.presence || Rails.application.credentials.dig(:aws, :region).to_s.presence || "us-east-1"
      end

      def extract_labels(response)
        Array(response[:labels] || response["labels"]).map { |l| (l[:name] || l["name"]).to_s.downcase.strip }.reject(&:blank?).uniq
      end

      def infer_author_type(post_payload)
        tags = Array(post_payload.dig(:author_profile, :tags)).map(&:to_s)
        return "relative" if tags.include?("relative")
        return "friend" if (tags & %w[friend female_friend male_friend]).any?
        return "page" if tags.include?("page")
        return "personal_user" if tags.include?("personal_user")

        "unknown"
      end

      def build_comment_suggestions(labels:)
        tag = labels.first.presence || "post"
        [
          "This #{tag} post is super clean 🔥",
          "Big fan of this vibe, nice one 👏",
          "This is giving, love this shot ✨"
        ]
      end
    end
  end
end
