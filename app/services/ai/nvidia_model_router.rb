module Ai
  # Maps a semantic role ("vision_primary", "text_quality", ...) to a
  # concrete AiProviderSetting row on the nvidia provider. Used by the
  # NvidiaProvider + downstream services so call-sites never hardcode
  # NVIDIA model names.
  #
  # On load failure (role not configured / disabled / no key) the router
  # can either raise or fall through to a configured fallback role.
  class NvidiaModelRouter
    class UnconfiguredRoleError < StandardError; end

    PROVIDER_KEY = "nvidia".freeze

    # Fallback chain per role. Keep this small; callers can pass an
    # override via `fallback_roles:`.
    DEFAULT_FALLBACKS = {
      "text_quality"    => %w[text_fast],
      "text_fast"       => %w[text_quality],
      "vision_primary"  => %w[vision_fallback],
      "vision_fallback" => %w[vision_primary],
      "embedding"       => []
    }.freeze

    # Defaults used by AiProviderSetting seeding and tests. Not wired to
    # the runtime; real model choices live in AiProviderSetting rows so
    # ops can change them without a deploy.
    DEFAULT_MODELS = {
      "text_fast"       => "meta/llama-3.1-8b-instruct",
      "text_quality"    => "meta/llama-3.3-70b-instruct",
      "vision_primary"  => "meta/llama-3.2-90b-vision-instruct",
      "vision_fallback" => "microsoft/phi-3-vision-128k-instruct",
      "embedding"       => "nvidia/nv-embedqa-e5-v5"
    }.freeze

    class << self
      # Returns an AiProviderSetting (enabled, with key) for the role,
      # walking fallbacks if the primary isn't usable.
      def resolve!(role, fallback_roles: nil)
        role = role.to_s
        candidates = [role] + Array(fallback_roles || DEFAULT_FALLBACKS[role])
        candidates.uniq.each do |candidate|
          setting = AiProviderSetting
                      .for_provider(PROVIDER_KEY)
                      .for_role(candidate)
                      .where(enabled: true)
                      .order(priority: :asc)
                      .first
          next unless setting
          next unless setting.api_key_present?
          next if setting.effective_model.blank?

          return setting
        end

        raise UnconfiguredRoleError, "No enabled nvidia provider row with a usable api_key + model for role=#{role} (tried: #{candidates.join(', ')})"
      end

      # Non-raising lookup; returns nil when nothing is configured.
      def resolve(role, fallback_roles: nil)
        resolve!(role, fallback_roles: fallback_roles)
      rescue UnconfiguredRoleError
        nil
      end

      def model_for(role, fallback_roles: nil)
        resolve!(role, fallback_roles: fallback_roles).effective_model
      end

      def roles
        AiProviderSetting::ROLES
      end
    end
  end
end
