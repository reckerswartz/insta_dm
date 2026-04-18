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
    it "invokes NVIDIA and records a successful AiAnalysis when it returns a result" do
      nvidia_provider = instance_double(Ai::Providers::NvidiaProvider,
                                        key: "nvidia",
                                        display_name: "NVIDIA Build (Text Quality)",
                                        preferred_model: "meta/llama-3.3-70b-instruct",
                                        available?: true)
      allow(nvidia_provider).to receive(:supports_profile?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_image?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_video?).and_return(true)

      allow(Ai::ProviderRegistry).to receive(:build_provider).with("nvidia", setting: anything).and_return(nvidia_provider)

      expect(nvidia_provider).to receive(:analyze_profile!).and_return(minimal_profile_result)

      result = described_class.new(account: account).analyze!(
        purpose: "profile",
        analyzable: profile,
        payload: { bio: "hi", can_message: true }
      )

      expect(result[:provider]).to eq(nvidia_provider)
      expect(AiAnalysis.last.provider).to eq("nvidia")
      expect(AiAnalysis.last.status).to eq("succeeded")
    end

    it "marks the analysis failed and raises when NVIDIA is the only enabled provider and it errors" do
      # Phase 9 deleted LocalProvider so there is no longer a fallback
      # candidate. The runner must surface the NVIDIA error to the caller
      # instead of silently returning a cached/fallback payload.
      nvidia_provider = instance_double(Ai::Providers::NvidiaProvider,
                                        key: "nvidia",
                                        display_name: "NVIDIA Build",
                                        preferred_model: "meta/llama-3.3-70b-instruct",
                                        available?: true)
      allow(nvidia_provider).to receive(:supports_profile?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_image?).and_return(true)
      allow(nvidia_provider).to receive(:supports_post_video?).and_return(true)

      allow(Ai::ProviderRegistry).to receive(:build_provider).with("nvidia", setting: anything).and_return(nvidia_provider)
      allow(nvidia_provider).to receive(:analyze_profile!).and_raise("NVIDIA down")

      expect do
        described_class.new(account: account).analyze!(
          purpose: "profile",
          analyzable: profile,
          payload: { bio: "hi", can_message: true }
        )
      end.to raise_error(/All enabled AI providers failed.*NVIDIA down/)

      expect(AiAnalysis.where(provider: "nvidia").last.status).to eq("failed")
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
