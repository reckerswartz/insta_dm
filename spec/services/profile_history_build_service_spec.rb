require "rails_helper"
require "securerandom"

RSpec.describe Ai::ProfileHistoryBuildService do
  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      display_name: "Profile User"
    )
    [ account, profile ]
  end

  it "marks history ready when checks, preparation, and face verification are complete" do
    account, profile = build_account_profile
    service = described_class.new(account: account, profile: profile)

    allow_any_instance_of(Instagram::ProfileScanPolicy).to receive(:decision).and_return(
      { skip_post_analysis: false }
    )
    allow(service).to receive(:collect_posts).and_return(summary: { feed_fetch: { source: "http_feed_api", pages_fetched: 1, more_available: false } })
    allow(service).to receive(:build_capture_checks).and_return(
      {
        "all_posts_captured" => { "ready" => true },
        "latest_50_captured" => { "ready" => true },
        "latest_20_analyzed" => { "ready" => true }
      }
    )
    allow(service).to receive(:queue_missing_media_downloads).and_return(queued_count: 0, pending_count: 0, skipped_count: 0, failures: [])
    allow(service).to receive(:queue_missing_post_analysis).and_return(queued_count: 0, pending_count: 0, skipped_count: 0, failures: [])
    allow(service).to receive(:prepare_history_summary).and_return(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context ready."
      }
    )
    allow(service).to receive(:verify_face_identity).and_return(
      {
        "confirmed" => true,
        "reason_code" => "identity_confirmed",
        "reason" => "Identity confirmed."
      }
    )
    allow(service).to receive(:build_conversation_state).and_return(
      {
        "can_generate_initial_message" => true,
        "can_respond_to_existing_messages" => false,
        "continue_natural_interaction" => true
      }
    )

    result = service.execute!

    expect(result[:status]).to eq("ready")
    expect(result[:ready]).to eq(true)
    expect(result[:reason_code]).to eq("history_ready")
    expect(profile.instagram_profile_behavior_profile.metadata.dig("history_build", "ready")).to eq(true)
  end

  it "stays pending and marks retryable_profile_incomplete when preparation is incomplete" do
    account, profile = build_account_profile
    service = described_class.new(account: account, profile: profile)

    allow_any_instance_of(Instagram::ProfileScanPolicy).to receive(:decision).and_return(
      { skip_post_analysis: false }
    )
    allow(service).to receive(:collect_posts).and_return(summary: { feed_fetch: { source: "http_feed_api", pages_fetched: 1, more_available: false } })
    allow(service).to receive(:build_capture_checks).and_return(
      {
        "all_posts_captured" => { "ready" => true },
        "latest_50_captured" => { "ready" => true },
        "latest_20_analyzed" => { "ready" => true }
      }
    )
    allow(service).to receive(:queue_missing_media_downloads).and_return(queued_count: 0, pending_count: 0, skipped_count: 0, failures: [])
    allow(service).to receive(:queue_missing_post_analysis).and_return(queued_count: 0, pending_count: 0, skipped_count: 0, failures: [])
    allow(service).to receive(:prepare_history_summary).and_return(
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are still analyzing."
      }
    )
    allow(service).to receive(:verify_face_identity).and_return(
      {
        "confirmed" => true,
        "reason_code" => "identity_confirmed",
        "reason" => "Identity confirmed."
      }
    )
    allow(service).to receive(:build_conversation_state).and_return(
      {
        "can_generate_initial_message" => false,
        "can_respond_to_existing_messages" => false,
        "continue_natural_interaction" => false
      }
    )

    result = service.execute!

    expect(result[:status]).to eq("pending")
    expect(result[:ready]).to eq(false)
    expect(result[:reason_code]).to eq("latest_posts_not_analyzed")
    expect(result[:retryable_profile_incomplete]).to eq(true)
    expect(profile.instagram_profile_behavior_profile.metadata.dig("history_build", "reason_code")).to eq("latest_posts_not_analyzed")
  end
end
