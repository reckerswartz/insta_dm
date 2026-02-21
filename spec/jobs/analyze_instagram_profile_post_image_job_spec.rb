require "rails_helper"
require "securerandom"

RSpec.describe AnalyzeInstagramProfilePostImageJob do
  it "runs image description service and stamps completion state" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: {},
      metadata: {}
    )

    service = instance_double(Ai::ProfilePostImageDescriptionService)
    allow(Ai::ProfilePostImageDescriptionService).to receive(:new).with(
      account: account,
      profile: profile,
      post: post
    ).and_return(service)
    allow(service).to receive(:run!).and_return(
      {
        "provider" => "local_ai",
        "model" => "stub",
        "analysis" => { "image_description" => "A portrait photo." }
      }
    )

    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      source_job: "spec"
    )

    post.reload
    state = post.metadata["profile_image_description"]
    expect(state["status"]).to eq("completed")
    expect(state["source_job"]).to eq("spec")
    expect(state["started_at"]).to be_present
    expect(state["completed_at"]).to be_present
  end

  it "stamps failure state when service raises" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      analysis: {},
      metadata: {}
    )

    service = instance_double(Ai::ProfilePostImageDescriptionService)
    allow(Ai::ProfilePostImageDescriptionService).to receive(:new).and_return(service)
    allow(service).to receive(:run!).and_raise(StandardError, "failed stub")

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        source_job: "spec"
      )
    end.to raise_error(StandardError, "failed stub")

    post.reload
    state = post.metadata["profile_image_description"]
    expect(state["status"]).to eq("failed")
    expect(state["error_class"]).to eq("StandardError")
    expect(state["error_message"]).to include("failed stub")
  end
end
