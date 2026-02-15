class AiProviderSetting < ApplicationRecord
  SUPPORTED_PROVIDERS = %w[local].freeze

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
    when "local" then "Local AI Microservice"
    else provider.to_s.humanize
    end
  end

  def effective_api_key
    return api_key.to_s if api_key.to_s.present?
    ""
  end

  def effective_model
    model = config_value("model").to_s
    return model if model.present?
    ""
  end

  def api_key_present?
    effective_api_key.present?
  end
end
