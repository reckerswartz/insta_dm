require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe Ai::ProfileHistoryBuildService do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

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

  it "queues face refresh work instead of running full face analysis inline" do
    account, profile = build_account_profile
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "analyzed",
      analyzed_at: Time.current,
      metadata: {}
    )
    post.media.attach(
      io: StringIO.new("image-bytes"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

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
        "reason" => "Profile context is ready."
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

    enqueued = enqueued_jobs.select { |row| row[:job] == RefreshProfilePostFaceIdentityJob }
    expect(enqueued.length).to eq(1)
    expect(result[:status]).to eq("pending")
    expect(result[:reason_code]).to eq("waiting_for_face_refresh")
    expect(result.dig(:history_state, "queue", "face_refresh_queued")).to eq(1)
    expect(post.reload.metadata.dig("history_build", "face_refresh", "status")).to eq("queued")
  end

  it "defers face verification when recent post analysis is still pending" do
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
        "latest_20_analyzed" => { "ready" => false, "reason_code" => "latest_posts_not_analyzed" }
      }
    )
    allow(service).to receive(:queue_missing_media_downloads).and_return(queued_count: 0, pending_count: 0, skipped_count: 0, failures: [])
    allow(service).to receive(:queue_missing_post_analysis).and_return(queued_count: 0, pending_count: 1, skipped_count: 0, failures: [])
    allow(service).to receive(:prepare_history_summary).and_return(
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are still analyzing."
      }
    )
    allow(service).to receive(:build_conversation_state).and_return(
      {
        "can_generate_initial_message" => false,
        "can_respond_to_existing_messages" => false,
        "continue_natural_interaction" => false
      }
    )
    expect(service).not_to receive(:verify_face_identity)

    result = service.execute!

    enqueued = enqueued_jobs.select { |row| row[:job] == RefreshProfilePostFaceIdentityJob }
    expect(enqueued).to be_empty
    expect(result[:status]).to eq("pending")
    expect(result[:reason_code]).to eq("latest_posts_not_analyzed")
    expect(result.dig(:history_state, "queue", "face_refresh_queued")).to eq(0)
  end

  it "does not immediately requeue face refresh when recent face recognition metadata exists" do
    account, profile = build_account_profile
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "analyzed",
      analyzed_at: Time.current,
      metadata: {
        "face_recognition" => {
          "updated_at" => Time.current.iso8601,
          "face_count" => 0
        }
      }
    )
    post.media.attach(
      io: StringIO.new("image-bytes"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

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
        "reason" => "Profile context is ready."
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

    enqueued = enqueued_jobs.select { |row| row[:job] == RefreshProfilePostFaceIdentityJob }
    expect(enqueued).to be_empty
    expect(result[:status]).to eq("pending")
    expect(result[:reason_code]).to eq("insufficient_face_data")
    expect(result.dig(:history_state, "queue", "face_refresh_queued")).to eq(0)
    expect(post.reload.metadata.dig("history_build", "face_refresh")).to be_nil
  end
end
