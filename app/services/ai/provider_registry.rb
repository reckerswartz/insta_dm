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

      def default_enabled?(provider)
        case provider
        when "local"  then true  # Local provider is always available if services are running
        when "nvidia" then false # Disabled until keys/roles are configured via admin
        else false
        end
      end

      def default_priority(provider)
        case provider
        when "local"  then 1  # Highest priority for local processing
        when "nvidia" then 2
        else 100
        end
      end
    end
  end
end
