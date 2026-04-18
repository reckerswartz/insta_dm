require "rails_helper"

RSpec.describe Ai::Runner, type: :service do
  let(:account) { InstagramAccount.create!(username: "runner_#{SecureRandom.hex(4)}") }
  let(:profile) do
    account.instagram_profiles.create!(
      username: "target_#{SecureRandom.hex(4)}",
      following: true,
      follows_you: true
    )
  end

  before do
    Ai::ProviderRegistry.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: true, api_key: "nvapi-test")
  end

  describe "#analyze! routing" do
    it "tries NVIDIA before LocalProvider and short-circuits when NVIDIA succeeds" do
      nvidia_provider = instance_double(Ai::Providers::NvidiaProvider,
                                        key: "nvidia",
                                        display_name: "NVIDIA Build (Text Quality)",
                                        preferred_model: "meta/llama-3.3-70b-instruct",
                                        available?: true)
      allow(nvidia_provider).to receive(:supports_profile?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_image?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_video?).and_return(true)

      local_provider = instance_double(Ai::Providers::LocalProvider,
                                       key: "local",
                                       display_name: "Local AI Microservice",
                                       preferred_model: "local-rules",
                                       available?: true)
      allow(local_provider).to receive(:supports_profile?).and_return(true)
      allow(local_provider).to receive(:supports_post_image?).and_return(true)
      allow(local_provider).to receive(:supports_post_video?).and_return(true)

      allow(Ai::ProviderRegistry).to receive(:build_provider) do |key, setting: nil|
        case key
        when "nvidia" then nvidia_provider
        when "local"  then local_provider
        end
      end

      expect(nvidia_provider).to receive(:analyze_profile!).and_return(minimal_profile_result)
      expect(local_provider).not_to receive(:analyze_profile!)

      result = described_class.new(account: account).analyze!(
        purpose: "profile",
        analyzable: profile,
        payload: { bio: "hi", can_message: true }
      )

      expect(result[:provider]).to eq(nvidia_provider)
      expect(AiAnalysis.last.provider).to eq("nvidia")
      expect(AiAnalysis.last.status).to eq("succeeded")
    end

    it "falls back to LocalProvider when NVIDIA raises" do
      nvidia_provider = instance_double(Ai::Providers::NvidiaProvider,
                                        key: "nvidia",
                                        display_name: "NVIDIA Build",
                                        preferred_model: "meta/llama-3.3-70b-instruct",
                                        available?: true)
      allow(nvidia_provider).to receive(:supports_profile?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_image?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_video?).and_return(true)

      local_provider = instance_double(Ai::Providers::LocalProvider,
                                       key: "local",
                                       display_name: "Local AI Microservice",
                                       preferred_model: "local-rules",
                                       available?: true)
      allow(local_provider).to receive(:supports_profile?).and_return(true)
      allow(local_provider).to receive(:supports_post_image?).and_return(true)
      allow(local_provider).to receive(:supports_post_video?).and_return(true)

      allow(Ai::ProviderRegistry).to receive(:build_provider) do |key, setting: nil|
        case key
        when "nvidia" then nvidia_provider
        when "local"  then local_provider
        end
      end

      allow(nvidia_provider).to receive(:analyze_profile!).and_raise("NVIDIA down")
      expect(local_provider).to receive(:analyze_profile!).and_return(minimal_profile_result)

      result = described_class.new(account: account).analyze!(
        purpose: "profile",
        analyzable: profile,
        payload: { bio: "hi", can_message: true }
      )

      expect(result[:provider]).to eq(local_provider)
      expect(AiAnalysis.where(provider: "nvidia").last.status).to eq("failed")
      expect(AiAnalysis.where(provider: "local").last.status).to eq("succeeded")
    end
  end

  def minimal_profile_result
    {
      model: "m1",
      prompt: { provider: "nvidia" },
      response_text: "ok",
      response_raw: {},
      analysis: {
        "summary" => "s",
        "languages" => [{ "language" => "English", "confidence" => 0.8, "evidence" => "bio" }],
        "likes" => [], "dislikes" => [], "intent_labels" => [], "conversation_hooks" => [],
        "personalization_tokens" => [], "no_go_zones" => [],
        "writing_style" => { "tone" => "warm", "formality" => "casual", "emoji_usage" => "low", "slang_level" => "low", "evidence" => "" },
        "response_style_prediction" => "responsive",
        "engagement_probability" => 0.5,
        "recommended_next_action" => "comment",
        "demographic_estimates" => { "age" => nil, "age_confidence" => 0, "gender" => nil, "gender_confidence" => 0, "location" => nil, "location_confidence" => 0, "evidence" => "" },
        "self_declared" => { "age" => nil, "gender" => nil, "location" => nil, "pronouns" => nil, "other" => nil },
        "suggested_dm_openers" => ["hi"],
        "suggested_comment_templates" => ["nice"],
        "confidence_notes" => "",
        "why_not_confident" => ""
      }
    }
  end
end
