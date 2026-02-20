require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "RefreshProfilePostFaceIdentityJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "updates history-build face refresh state around recognition execution" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      display_name: "Profile User"
    )
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

    allow_any_instance_of(PostFaceRecognitionService).to receive(:process!).and_return(
      {
        skipped: false,
        reason: nil,
        face_count: 2,
        linked_face_count: 1,
        low_confidence_filtered_count: 1,
        matched_people: [ { person_id: 12 } ]
      }
    )

    RefreshProfilePostFaceIdentityJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id
    )

    state = post.reload.metadata.dig("history_build", "face_refresh")
    expect(state["status"]).to eq("completed")
    expect(state["started_at"]).to be_present
    expect(state["finished_at"]).to be_present
    expect(state.dig("result", "face_count")).to eq(2)
    expect(state.dig("result", "matched_people_count")).to eq(1)
  end
end
