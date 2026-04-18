module Ai
  class ProviderRegistry
    PROVIDERS = {
      "local"  => "Ai::Providers::LocalProvider",
      "nvidia" => "Ai::Providers::NvidiaProvider"
    }.freeze

    # Providers listed here create one row per role (see AiProviderSetting::ROLES)
    # instead of the legacy single-row-per-provider pattern.
    MULTI_ROLE_PROVIDERS = %w[nvidia].freeze

    class << self
      def provider_keys
        PROVIDERS.keys
      end

      def ensure_settings!
        provider_keys.each do |provider|
          if MULTI_ROLE_PROVIDERS.include?(provider)
            AiProviderSetting::ROLES.each do |role|
              AiProviderSetting.find_or_create_by!(provider: provider, role: role) do |row|
                row.enabled = default_enabled?(provider)
                row.priority = default_priority(provider)
                row.model = Ai::NvidiaModelRouter::DEFAULT_MODELS[role] if provider == "nvidia"
                row.base_url = "https://integrate.api.nvidia.com/v1" if provider == "nvidia"
              end
            end
          else
            AiProviderSetting.find_or_create_by!(provider: provider, role: nil) do |row|
              row.enabled = default_enabled?(provider)
              row.priority = default_priority(provider)
            end
          end
        end
      end

      def enabled_settings
        ensure_settings!
        AiProviderSetting.where(provider: provider_keys, enabled: true).order(priority: :asc, provider: :asc)
      end

      def all_settings
        ensure_settings!
        AiProviderSetting.where(provider: provider_keys).enabled_first
      end

      def build_provider(provider_key, setting: nil)
        klass_name = PROVIDERS[provider_key.to_s]
        raise "Unsupported AI provider: #{provider_key}" if klass_name.blank?

        # For multi-role providers, pick an arbitrary enabled row so the
        # provider instance has *some* AiProviderSetting context; per-call
        # role resolution happens inside the provider via Ai::NvidiaModelRouter.
        setting ||=
          if MULTI_ROLE_PROVIDERS.include?(provider_key.to_s)
            AiProviderSetting.for_provider(provider_key).enabled_first.first
          else
            AiProviderSetting.find_by(provider: provider_key)
          end

        klass_name.constantize.new(setting: setting)
      end

      private

      # Seed-time defaults. NVIDIA rows auto-enable when the shared
      # credential key is present -- in that case the operator has already
      # opted in by configuring credentials, so we shouldn't make them
      # re-enable rows manually. Without the key, nvidia stays dormant
      # and the admin UI shows the row in a disabled state for opt-in.
      def default_enabled?(provider)
        case provider
        when "local"  then true
        when "nvidia" then nvidia_credential_key_present?
        else false
        end
      end

      # Lower = tried first by Ai::Runner. NVIDIA now outranks the legacy
      # local stack so the new provider is the primary path on any account
      # with it enabled. Local remains as a fallback when NVIDIA errors.
      def default_priority(provider)
        case provider
        when "nvidia" then 2
        when "local"  then 20
        else 100
        end
      end

      def nvidia_credential_key_present?
        Rails.application.credentials.dig(:nvidia, :api_key).to_s.present?
      rescue StandardError
        false
      end
    end
  end
end
