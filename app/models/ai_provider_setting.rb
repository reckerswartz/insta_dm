class AiProviderSetting < ApplicationRecord
  SUPPORTED_PROVIDERS = %w[xai google_cloud azure_vision aws_rekognition].freeze

  encrypts :api_key

  validates :provider, presence: true, inclusion: { in: SUPPORTED_PROVIDERS }
  validates :provider, uniqueness: true
  validates :priority, numericality: { greater_than_or_equal_to: 0 }

  scope :enabled_first, -> { order(enabled: :desc, priority: :asc, provider: :asc) }

  def config_hash
    value = config
    return {} unless value.is_a?(Hash)

    value.stringify_keys
  end

  def config_value(key)
    config_hash[key.to_s]
  end

  def set_config_value(key, value)
    merged = config_hash
    if value.present?
      merged[key.to_s] = value
    else
      merged.delete(key.to_s)
    end
    self.config = merged
  end

  def display_name
    case provider
    when "xai" then "Grok (xAI)"
    when "google_cloud" then "Google Cloud AI"
    when "azure_vision" then "Azure AI Vision"
    when "aws_rekognition" then "AWS Rekognition"
    else provider.to_s.humanize
    end
  end

  def effective_api_key
    return api_key.to_s if api_key.to_s.present?

    case provider
    when "xai"
      Rails.application.credentials.dig(:xai, :api_key).to_s
    when "google_cloud"
      Rails.application.credentials.dig(:google_cloud, :api_key).to_s
    when "azure_vision"
      Rails.application.credentials.dig(:azure_vision, :api_key).to_s
    when "aws_rekognition"
      Rails.application.credentials.dig(:aws, :secret_access_key).to_s
    else
      ""
    end
  end

  def effective_model
    model = config_value("model").to_s
    return model if model.present?

    case provider
    when "xai"
      Rails.application.credentials.dig(:xai, :model).to_s
    else
      ""
    end
  end

  def api_key_present?
    effective_api_key.present?
  end
end
