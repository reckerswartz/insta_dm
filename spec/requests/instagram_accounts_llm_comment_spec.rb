require "rails_helper"
require "securerandom"

RSpec.describe "InstagramAccounts generate_llm_comment", type: :request do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "enqueues regenerate_all mode when requested" do
    account = InstagramAccount.create!(username: "acct_req_llm_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_req_llm_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_req_llm_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "completed",
      llm_generated_comment: "Old comment",
      llm_comment_generated_at: 1.hour.ago,
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-old-req-1",
          "status" => "failed",
          "steps" => {
            "metadata_extraction" => { "status" => "succeeded" }
          }
        }
      },
      metadata: {}
    )

    expect do
      post generate_llm_comment_instagram_account_path(account), params: {
        event_id: event.id,
        provider: "local",
        force: true,
        regenerate_all: true
      }, as: :json
    end.to have_enqueued_job(GenerateLlmCommentJob).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: nil,
      requested_by: "dashboard_manual_request",
      regenerate_all: true
    )

    expect(response).to have_http_status(:accepted)
    payload = JSON.parse(response.body)
    expect(payload["status"]).to eq("queued")
    expect(payload["regenerate_all"]).to eq(true)
  end

  it "defaults to resumable mode when regenerate_all is false" do
    account = InstagramAccount.create!(username: "acct_req_llm_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_req_llm_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_req_llm_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "completed",
      llm_generated_comment: "Old comment",
      llm_comment_generated_at: 1.hour.ago,
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-old-req-2",
          "status" => "failed",
          "steps" => {
            "metadata_extraction" => { "status" => "succeeded" }
          }
        }
      },
      metadata: {}
    )

    expect do
      post generate_llm_comment_instagram_account_path(account), params: {
        event_id: event.id,
        provider: "local",
        force: true,
        regenerate_all: false
      }, as: :json
    end.to have_enqueued_job(GenerateLlmCommentJob).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: nil,
      requested_by: "dashboard_manual_request",
      regenerate_all: false
    )

    expect(response).to have_http_status(:accepted)
    payload = JSON.parse(response.body)
    expect(payload["status"]).to eq("queued")
    expect(payload["regenerate_all"]).to eq(false)
  end
end
