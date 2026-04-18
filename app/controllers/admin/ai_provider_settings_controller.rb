class Admin::AiProviderSettingsController < Admin::BaseController
  before_action :ensure_seeds!
  before_action :load_setting, only: %i[update test_key]

  def index
    @nvidia_rows = AiProviderSetting.for_provider("nvidia").order(:role)
    @local_rows  = AiProviderSetting.for_provider("local").order(:id)
    @credential_key_present = Rails.application.credentials.dig(:nvidia, :api_key).to_s.present?
  end

  def update
    if @setting.update(permitted_params)
      flash[:notice] = "Saved #{@setting.display_name}."
    else
      flash[:alert] = @setting.errors.full_messages.to_sentence
    end
    redirect_to admin_ai_provider_settings_path
  end

  def test_key
    result =
      begin
        Ai::NvidiaClient.new(setting: @setting, max_retries: 0).list_models!
      rescue Ai::NvidiaClient::AuthError => e
        { ok: false, error_class: e.class.name, error: e.message[0, 300] }
      rescue StandardError => e
        { ok: false, error_class: e.class.name, error: e.message[0, 300] }
      end

    respond_to do |format|
      format.json { render json: render_test_result(result) }
      format.html do
        flash[json_ok?(result) ? :notice : :alert] = flash_for(result)
        redirect_to admin_ai_provider_settings_path
      end
    end
  end

  private

  def ensure_seeds!
    Ai::ProviderRegistry.ensure_settings!
  end

  def load_setting
    @setting = AiProviderSetting.find(params[:id])
  end

  def permitted_params
    attrs = params.require(:ai_provider_setting).permit(:enabled, :priority, :model,
                                                        :base_url, :api_key,
                                                        :request_timeout_seconds,
                                                        :rate_limit_rpm,
                                                        :display_label)
    # Don't clobber a saved key when the form submits a blank field.
    attrs.delete(:api_key) if attrs[:api_key].to_s.empty?
    attrs
  end

  def render_test_result(result)
    return { ok: false, error: result[:error], error_class: result[:error_class] } if result.is_a?(Hash) && result[:ok] == false

    { ok: true, models_count: Array(result["data"]).length }
  end

  def json_ok?(result)
    !(result.is_a?(Hash) && result[:ok] == false)
  end

  def flash_for(result)
    if json_ok?(result)
      "NVIDIA key OK (#{Array(result["data"]).length} models available)."
    else
      "NVIDIA key check failed: #{result[:error_class]} #{result[:error]}"
    end
  end
end
