require "rails_helper"

RSpec.describe "Admin::AiProviderSettings", type: :request do
  before { Ai::ProviderRegistry.ensure_settings! }

  describe "GET /admin/ai_provider_settings" do
    it "renders the NVIDIA row table" do
      get "/admin/ai_provider_settings"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("NVIDIA Build")
      AiProviderSetting::ROLES.each { |role| expect(response.body).to include(role) }
    end

    it "no longer renders the Phase-4-deprecated Local provider (legacy) block" do
      get "/admin/ai_provider_settings"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Local provider (legacy)")
      expect(response.body).not_to include("Phase 4 of the NVIDIA migration")
    end
  end

  describe "PATCH /admin/ai_provider_settings/:id" do
    let(:row) { AiProviderSetting.for_provider("nvidia").for_role("text_quality").first! }

    it "updates model + toggles enabled, and does not clobber key when the field is blank" do
      row.update!(api_key: "nvapi-original")

      patch "/admin/ai_provider_settings/#{row.id}",
            params: { ai_provider_setting: { enabled: "1", model: "meta/llama-3.3-70b-instruct", api_key: "" } }

      expect(response).to redirect_to(admin_ai_provider_settings_path)
      row.reload
      expect(row.enabled).to be(true)
      expect(row.model).to eq("meta/llama-3.3-70b-instruct")
      expect(row.api_key).to eq("nvapi-original")
    end

    it "stores a new api_key when provided" do
      patch "/admin/ai_provider_settings/#{row.id}",
            params: { ai_provider_setting: { api_key: "nvapi-freshly-typed" } }

      expect(row.reload.api_key).to eq("nvapi-freshly-typed")
    end
  end

  describe "POST /admin/ai_provider_settings/:id/test_key" do
    let(:row) do
      setting = AiProviderSetting.for_provider("nvidia").for_role("text_quality").first!
      setting.update!(enabled: true, api_key: "nvapi-test", model: "meta/llama-3.3-70b-instruct")
      setting
    end

    it "returns JSON success when /models returns 200" do
      stub_request(:get, "https://integrate.api.nvidia.com/v1/models")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { data: [{ id: "m1" }, { id: "m2" }] }.to_json)

      post "/admin/ai_provider_settings/#{row.id}/test_key", as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include("ok" => true, "models_count" => 2)
    end

    it "returns error JSON when /models returns 401" do
      stub_request(:get, "https://integrate.api.nvidia.com/v1/models")
        .to_return(status: 401, body: '{"error":"nope"}')

      post "/admin/ai_provider_settings/#{row.id}/test_key", as: :json
      body = JSON.parse(response.body)
      expect(body).to include("ok" => false)
      expect(body["error_class"]).to eq("Ai::NvidiaClient::AuthError")
    end
  end
end
