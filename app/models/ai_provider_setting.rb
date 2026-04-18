class AiProviderSetting < ApplicationRecord
  SUPPORTED_PROVIDERS = %w[nvidia].freeze

  # Role values that the NVIDIA provider's router understands. Every
  # supported provider after the Phase 9 cleanup is role-aware; a future
  # single-role provider would introduce a new constant rather than
  # branching on nil.
  ROLES = %w[text_fast text_quality vision_primary vision_fallback embedding].freeze

  MULTI_ROLE_PROVIDERS = %w[nvidia].freeze

  encrypts :api_key

  validates :provider, presence: true, inclusion: { in: SUPPORTED_PROVIDERS }
  validates :priority, numericality: { greater_than_or_equal_to: 0 }
  validates :role, inclusion: { in: ROLES, allow_nil: true }
  validate :role_presence_matches_provider
  validates :provider, uniqueness: { scope: :role }

  scope :enabled_first, -> { order(enabled: :desc, priority: :asc, provider: :asc, role: :asc) }
  scope :for_provider, ->(key) { where(provider: key.to_s) }
  scope :for_role, ->(role) { where(role: role.to_s) }

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
    return display_label if display_label.present?

    base =
      case provider
      when "nvidia" then "NVIDIA Build"
      else provider.to_s.humanize
      end

    role.present? ? "#{base} (#{role.humanize})" : base
  end

  def effective_api_key
    return api_key.to_s if api_key.to_s.present?

    # Fall back to Rails credentials for providers that have a canonical
    # shared key (nvidia). Per-role keys in the DB always win.
    case provider
    when "nvidia" then Rails.application.credentials.dig(:nvidia, :api_key).to_s
    else ""
    end
  end

  def effective_base_url
    return base_url.to_s if base_url.to_s.present?

    case provider
    when "nvidia"
      Rails.application.credentials.dig(:nvidia, :base_url).presence ||
        "https://integrate.api.nvidia.com/v1"
    else ""
    end
  end

  def effective_model
    return model.to_s if model.to_s.present?

    configured = config_value("model").to_s
    return configured if configured.present?

    ""
  end

  def api_key_present?
    effective_api_key.present?
  end

  private

  def role_presence_matches_provider
    if MULTI_ROLE_PROVIDERS.include?(provider) && role.blank?
      errors.add(:role, "must be set for provider #{provider}")
    end
  end
end

