module Ai
  class ProviderRegistry
    PROVIDERS = {
      "xai" => "Ai::Providers::XaiProvider",
      "google_cloud" => "Ai::Providers::GoogleCloudProvider",
      "azure_vision" => "Ai::Providers::AzureVisionProvider",
      "aws_rekognition" => "Ai::Providers::AwsRekognitionProvider"
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
        when "xai"
          Rails.application.credentials.dig(:xai, :api_key).to_s.present?
        when "google_cloud"
          Rails.application.credentials.dig(:google_cloud, :api_key).to_s.present?
        when "azure_vision"
          Rails.application.credentials.dig(:azure_vision, :api_key).to_s.present?
        when "aws_rekognition"
          Rails.application.credentials.dig(:aws, :access_key_id).to_s.present? &&
            Rails.application.credentials.dig(:aws, :secret_access_key).to_s.present?
        else
          false
        end
      end

      def default_priority(provider)
        case provider
        when "google_cloud" then 10
        when "azure_vision" then 20
        when "aws_rekognition" then 30
        when "xai" then 40
        else 100
        end
      end
    end
  end
end
