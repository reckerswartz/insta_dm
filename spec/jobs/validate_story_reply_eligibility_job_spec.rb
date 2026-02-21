require "rails_helper"
require "securerandom"

RSpec.describe ValidateStoryReplyEligibilityJob do
  it "returns ineligible when interaction retry window is active" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "story_user_#{SecureRandom.hex(3)}",
      story_interaction_state: "unavailable",
      story_interaction_reason: "api_can_reply_false",
      story_interaction_retry_after_at: 2.hours.from_now
    )

    expect(Instagram::Client).not_to receive(:new)

    result = described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_username: profile.username,
      story_id: "12345"
    )

    expect(result[:eligible]).to eq(false)
    expect(result[:reason_code]).to eq("interaction_retry_window_active")
    expect(result[:interaction_retry_active]).to eq(true)
    expect(result[:retry_after_at]).to be_present
  end

  it "marks profile unavailable and returns ineligible when API gate disallows replies" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")

    result = described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_username: profile.username,
      story_id: "56789",
      api_reply_gate: {
        known: true,
        reply_possible: false,
        reason_code: "api_can_reply_false",
        status: "Replies not allowed (API)"
      }
    )

    expect(result[:eligible]).to eq(false)
    expect(result[:reason_code]).to eq("api_can_reply_false")
    expect(result[:status]).to eq("Replies not allowed (API)")
    expect(result[:retry_after_at]).to be_present

    profile.reload
    expect(profile.story_interaction_state).to eq("unavailable")
    expect(profile.story_interaction_reason).to eq("api_can_reply_false")
    expect(profile.story_interaction_retry_after_at).to be_present
    expect(profile.story_reaction_available).to eq(false)
  end

  it "returns eligible when API gate allows reply" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")

    result = described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_username: profile.username,
      story_id: "99887",
      api_reply_gate: {
        known: true,
        reply_possible: true,
        reason_code: nil,
        status: "Reply available (API)"
      }
    )

    expect(result[:eligible]).to eq(true)
    expect(result[:interaction_retry_active]).to eq(false)
    expect(result[:api_reply_gate]).to include(known: true, reply_possible: true)
  end

  it "fetches API gate when no precomputed gate is provided" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    expect(client).to receive(:send).with(
      :story_reply_capability_from_api,
      hash_including(username: profile.username, story_id: "24680", cache: {})
    ).and_return(
      {
        known: true,
        reply_possible: false,
        reason_code: "api_can_reply_false",
        status: "Replies not allowed (API)"
      }
    )

    result = described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_username: profile.username,
      story_id: "24680"
    )

    expect(result[:eligible]).to eq(false)
    expect(result[:reason_code]).to eq("api_can_reply_false")
  end
end
