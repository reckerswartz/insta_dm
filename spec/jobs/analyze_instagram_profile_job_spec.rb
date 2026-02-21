require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe AnalyzeInstagramProfileJob do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def build_stub_provider_run
    provider = Struct.new(:key, :display_name).new("local_ai", "Local AI")
    {
      provider: provider,
      result: {
        model: "stub-model",
        analysis: {}
      }
    }
  end

  def stub_analysis_dependencies(account:, profile:, posts:, run_result: build_stub_provider_run)
    collector = instance_double(Instagram::ProfileAnalysisCollector)
    allow(Instagram::ProfileAnalysisCollector).to receive(:new).with(account: account, profile: profile).and_return(collector)
    allow(collector).to receive(:collect_and_persist!).and_return({ posts: posts })

    runner = instance_double(Ai::Runner)
    allow(Ai::Runner).to receive(:new).with(account: account).and_return(runner)
    allow(runner).to receive(:analyze!).and_return(run_result)

    allow_any_instance_of(described_class).to receive(:build_accepted_media_context).and_return(
      accepted_profile_posts: [],
      accepted_story_images: []
    )
    allow_any_instance_of(described_class).to receive(:update_profile_demographics_from_analysis!).and_return(nil)
    allow_any_instance_of(described_class).to receive(:aggregate_demographics_from_accumulated_json!).and_return(nil)
  end

  it "enqueues per-post image description jobs instead of processing them inline" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: {},
      metadata: {}
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

    stub_analysis_dependencies(account: account, profile: profile, posts: [ post ])

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id
      )
    end.to have_enqueued_job(AnalyzeInstagramProfilePostImageJob).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        source_job: "AnalyzeInstagramProfileJob"
      )
    )

    post.reload
    state = post.metadata["profile_image_description"]
    expect(state).to be_a(Hash)
    expect(state["status"]).to eq("queued")
    expect(state["job_id"]).to be_present
  end

  it "enqueues a profile follow-up run from primary phase when post image descriptions are still pending" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: {},
      metadata: {
        "profile_image_description" => {
          "status" => "queued",
          "queued_at" => 15.seconds.ago.iso8601(3),
          "updated_at" => 15.seconds.ago.iso8601(3)
        }
      }
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )
    stub_analysis_dependencies(account: account, profile: profile, posts: [ post ])

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id
      )
    end.to have_enqueued_job(described_class).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        phase: "post_image_followup",
        post_image_followup_attempt: 1
      )
    )
  end

  it "returns early and re-enqueues follow-up phase when post image description jobs are pending" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: {},
      metadata: {
        "profile_image_description" => {
          "status" => "running",
          "started_at" => 10.seconds.ago.iso8601(3),
          "updated_at" => 10.seconds.ago.iso8601(3)
        }
      }
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )
    stub_analysis_dependencies(account: account, profile: profile, posts: [ post ])

    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "analyze_profile",
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current
    )

    expect(Ai::Runner).not_to receive(:new)
    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: action_log.id,
        phase: "post_image_followup",
        post_image_followup_attempt: 1
      )
    end.to have_enqueued_job(described_class).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        phase: "post_image_followup",
        post_image_followup_attempt: 2
      )
    )
  end

  it "does not broadcast completion notification in follow-up phase" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: { "image_description" => "A smiling person outdoors." },
      metadata: {}
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )
    stub_analysis_dependencies(account: account, profile: profile, posts: [ post ])

    expect(Turbo::StreamsChannel).not_to receive(:broadcast_append_to)
    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      phase: "post_image_followup",
      post_image_followup_attempt: 1
    )
  end
end
