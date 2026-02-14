class Admin::AiProvidersController < Admin::BaseController
  def index
    @settings = Ai::ProviderRegistry.all_settings
  end

  def update
    setting = AiProviderSetting.find(params[:id])

    setting.enabled = ActiveModel::Type::Boolean.new.cast(params.dig(:ai_provider_setting, :enabled))
    setting.priority = params.dig(:ai_provider_setting, :priority).to_i

    model = params.dig(:ai_provider_setting, :model).to_s.strip
    setting.set_config_value(:model, model.presence)
    comment_model = params.dig(:ai_provider_setting, :comment_model).to_s.strip
    setting.set_config_value(:comment_model, comment_model.presence)

    project_id = params.dig(:ai_provider_setting, :project_id).to_s.strip
    setting.set_config_value(:project_id, project_id.presence)
    endpoint = params.dig(:ai_provider_setting, :endpoint).to_s.strip
    setting.set_config_value(:endpoint, endpoint.presence)
    access_key_id = params.dig(:ai_provider_setting, :access_key_id).to_s.strip
    setting.set_config_value(:access_key_id, access_key_id.presence)
    region = params.dig(:ai_provider_setting, :region).to_s.strip
    setting.set_config_value(:region, region.presence)
    api_version = params.dig(:ai_provider_setting, :api_version).to_s.strip
    setting.set_config_value(:api_version, api_version.presence)
    daily_limit = params.dig(:ai_provider_setting, :daily_limit).to_s.strip
    setting.set_config_value(:daily_limit, daily_limit.presence)

    if ActiveModel::Type::Boolean.new.cast(params.dig(:ai_provider_setting, :clear_api_key))
      setting.api_key = nil
    else
      api_key = params.dig(:ai_provider_setting, :api_key).to_s
      setting.api_key = api_key.strip if api_key.present?
    end

    setting.save!

    redirect_to admin_ai_providers_path, notice: "Updated #{setting.display_name}."
  rescue StandardError => e
    redirect_to admin_ai_providers_path, alert: "Unable to update provider: #{e.message}"
  end

  def test_key
    setting = AiProviderSetting.find(params[:id])
    provider = Ai::ProviderRegistry.build_provider(setting.provider, setting: setting)
    result = provider.test_key!

    if result[:ok]
      redirect_to admin_ai_providers_path, notice: "#{setting.display_name}: #{result[:message]}"
    else
      redirect_to admin_ai_providers_path, alert: "#{setting.display_name}: #{result[:message]}"
    end
  rescue StandardError => e
    redirect_to admin_ai_providers_path, alert: "#{setting&.display_name || 'Provider'}: #{e.message}"
  end
end
