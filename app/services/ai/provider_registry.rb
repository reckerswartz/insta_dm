module Ai
  class ProviderRegistry
    PROVIDERS = {
      "local" => "Ai::Providers::LocalProvider"
    }.freeze

    class << self
      def provider_keys
        PROVIDERS.keys
      end

      def ensure_settings!
        provider_keys.each do |provider|
          AiProviderSetting.find_or_create_by!(provider: provider) do |row|
            row.enabled = default_enabled?(provider)
            row.priority = default_priority(provider)
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

        klass_name.constantize.new(setting: setting || AiProviderSetting.find_by(provider: provider_key))
      end

      private

      def default_enabled?(provider)
        case provider
        when "local"
          true  # Local provider is always available if services are running
        else
          false
        end
      end

      def default_priority(provider)
        case provider
        when "local" then 1      # Highest priority for local processing
        else 100
        end
      end
    end
  end
end
