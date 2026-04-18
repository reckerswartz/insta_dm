module Ai
  module Providers
    # NVIDIA Build provider. The provider itself is a thin dispatcher;
    # per-call work (chat / vision / embedding) happens in Ai::NvidiaClient
    # routed by role via Ai::NvidiaModelRouter.
    #
    # analyze_profile! / analyze_post! are stubbed until Phase 4 wires the
    # existing profile/post analyzers through this provider.
    class NvidiaProvider < BaseProvider
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

      def analyze_profile!(_profile_payload:, _media: nil)
        raise NotImplementedError, "NvidiaProvider#analyze_profile! will be wired in Phase 4 of the migration"
      end

      def analyze_post!(_post_payload:, _media: nil, _provider_options: {})
        raise NotImplementedError, "NvidiaProvider#analyze_post! will be wired in Phase 4 of the migration"
      end

      # Internal helpers other services can call once Phase 4 lands.
      def chat!(role:, messages:, **opts)
        row = Ai::NvidiaModelRouter.resolve!(role)
        Ai::NvidiaClient.new(setting: row, rate_limiter: Ai::NvidiaRateLimiter.new)
                        .chat!(model: row.effective_model, messages: messages, **opts)
      end

      def embed!(input:, role: "embedding", **opts)
        row = Ai::NvidiaModelRouter.resolve!(role)
        Ai::NvidiaClient.new(setting: row, rate_limiter: Ai::NvidiaRateLimiter.new)
                        .embed!(model: row.effective_model, input: input, **opts)
      end

      private

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
    end
  end
end
