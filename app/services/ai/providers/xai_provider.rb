module Ai
  module Providers
    class XaiProvider < BaseProvider
      DEFAULT_MODEL = "grok-4-1-fast-reasoning".freeze

      def key
        "xai"
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

      def test_key!
        client = Ai::XaiClient.new(api_key: ensure_api_key!)
        model = effective_model.presence || DEFAULT_MODEL

        client.chat_completions!(
          model: model,
          temperature: 0,
          max_tokens: 8,
          usage_category: "healthcheck",
          usage_context: { workflow: "xai_provider_test_key" },
          messages: [
            { role: "user", content: [ { type: "text", text: "Reply with JSON: {\"ok\":true}" } ] }
          ]
        )

        { ok: true, message: "API key is valid.", details: { model: model } }
      rescue StandardError => e
        { ok: false, message: e.message.to_s }
      end

      def analyze_profile!(profile_payload:, media: nil)
        model = effective_model.presence || DEFAULT_MODEL
        client = Ai::XaiClient.new(api_key: ensure_api_key!)

        Ai::ProfileAnalyzer.new(client: client, model: model).analyze!(
          profile_payload: profile_payload,
          images: Array(media).filter_map { |m| m[:url].to_s if m.is_a?(Hash) }
        )
      end

      def analyze_post!(post_payload:, media: nil)
        model = effective_model.presence || DEFAULT_MODEL
        client = Ai::XaiClient.new(api_key: ensure_api_key!)

        media_hash = media.is_a?(Hash) ? media : {}
        image_data_url = media_hash[:image_data_url]

        if media_hash[:type].to_s == "video"
          raise "#{display_name} is configured but does not support video analysis in this app"
        end

        Ai::PostAnalyzer.new(client: client, model: model).analyze!(
          post_payload: post_payload,
          image_data_url: image_data_url
        )
      end
    end
  end
end
