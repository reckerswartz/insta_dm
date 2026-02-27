require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramAccounts::StoryArchiveQuery do
  it "returns paginated story archive events scoped to account and optional date" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    older = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 3.hours.ago,
      occurred_at: Date.current.to_time.beginning_of_day + 2.hours,
      metadata: {}
    )
    older.media.attach(io: StringIO.new("older"), filename: "older.jpg", content_type: "image/jpeg")

    newer = profile.instagram_profile_events.create!(
      kind: "story_media_downloaded_via_feed",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 1.hour.ago,
      occurred_at: Date.current.to_time.beginning_of_day + 4.hours,
      metadata: {}
    )
    newer.media.attach(io: StringIO.new("newer"), filename: "newer.jpg", content_type: "image/jpeg")

    result = described_class.new(
      account: account,
      page: "1",
      per_page: "8",
      on: Date.current.iso8601
    ).call

    expect(result.page).to eq(1)
    expect(result.per_page).to eq(8)
    expect(result.total).to eq(2)
    expect(result.on).to eq(Date.current)
    expect(result.events.map(&:id)).to eq([newer.id, older.id])
  end

  it "returns nil date filter for invalid date values" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )
    event.media.attach(io: StringIO.new("one"), filename: "one.jpg", content_type: "image/jpeg")

    result = described_class.new(account: account, page: 1, per_page: 12, on: "invalid-date").call

    expect(result.on).to be_nil
    expect(result.total).to eq(1)
  end

  it "filters archive items by llm failure reason code" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    matching = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_match_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {},
      llm_comment_metadata: {
        "last_failure" => {
          "reason" => "local_microservice_disabled"
        }
      }
    )
    matching.media.attach(io: StringIO.new("match"), filename: "match.jpg", content_type: "image/jpeg")

    non_matching = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_other_#{SecureRandom.hex(4)}",
      detected_at: 5.minutes.ago,
      metadata: {},
      llm_comment_metadata: {
        "last_failure" => {
          "reason" => "vision_model_error"
        }
      }
    )
    non_matching.media.attach(io: StringIO.new("other"), filename: "other.jpg", content_type: "image/jpeg")

    result = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      reason_code: "LOCAL_MICROSERVICE_DISABLED"
    ).call

    expect(result.events.map(&:id)).to eq([matching.id])
    expect(result.total).to eq(1)
  end

  it "filters archive items by llm comment status" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    completed = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_completed_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {},
      llm_comment_status: "completed"
    )
    completed.media.attach(io: StringIO.new("done"), filename: "done.jpg", content_type: "image/jpeg")

    failed = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_failed_#{SecureRandom.hex(4)}",
      detected_at: 2.minutes.ago,
      metadata: {},
      llm_comment_status: "failed"
    )
    failed.media.attach(io: StringIO.new("failed"), filename: "failed.jpg", content_type: "image/jpeg")

    result = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      status: "FAILED"
    ).call

    expect(result.events.map(&:id)).to eq([failed.id])
    expect(result.total).to eq(1)
  end

  it "combines status and failure reason filters" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    matching = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_match_both_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {},
      llm_comment_status: "skipped",
      llm_comment_metadata: {
        "last_failure" => {
          "reason" => "local_microservice_disabled"
        }
      }
    )
    matching.media.attach(io: StringIO.new("both"), filename: "both.jpg", content_type: "image/jpeg")

    wrong_reason = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_wrong_reason_#{SecureRandom.hex(4)}",
      detected_at: 1.minute.ago,
      metadata: {},
      llm_comment_status: "skipped",
      llm_comment_metadata: {
        "last_failure" => {
          "reason" => "vision_model_error"
        }
      }
    )
    wrong_reason.media.attach(io: StringIO.new("reason"), filename: "reason.jpg", content_type: "image/jpeg")

    wrong_status = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_wrong_status_#{SecureRandom.hex(4)}",
      detected_at: 2.minutes.ago,
      metadata: {},
      llm_comment_status: "failed",
      llm_comment_metadata: {
        "last_failure" => {
          "reason" => "local_microservice_disabled"
        }
      }
    )
    wrong_status.media.attach(io: StringIO.new("status"), filename: "status.jpg", content_type: "image/jpeg")

    result = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      status: "skipped",
      reason_code: "local_microservice_disabled"
    ).call

    expect(result.events.map(&:id)).to eq([matching.id])
    expect(result.total).to eq(1)
  end

  it "normalizes stale in-progress llm status to failed while loading archive items" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {},
      llm_comment_status: "running",
      llm_comment_job_id: "job-stale"
    )
    event.media.attach(io: StringIO.new("one"), filename: "one.jpg", content_type: "image/jpeg")

    queue_inspector = instance_double(InstagramAccounts::LlmQueueInspector, stale_comment_job?: true)

    result = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      queue_inspector: queue_inspector
    ).call

    expect(result.events.map(&:id)).to include(event.id)
    expect(event.reload.llm_comment_status).to eq("failed")
    expect(event.llm_comment_last_error).to eq("Previous generation job appears stalled. Please retry.")
  end

  it "marks queued analysis rows as completed when analysis event already exists" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: { "story_id" => story_id }
    )
    event.media.attach(io: StringIO.new("one"), filename: "one.jpg", content_type: "image/jpeg")

    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { "story_id" => story_id, "status" => "queued" }
    )
    profile.record_event!(
      kind: "story_analyzed",
      external_id: "story_analyzed:#{story_id}:#{Time.current.utc.iso8601(6)}",
      metadata: { "story_id" => story_id }
    )

    query = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      analysis_queue_inspector: instance_double(InstagramAccounts::StoryAnalysisQueueInspector, stale_job?: false)
    )
    result = query.call

    expect(result.events.map(&:id)).to include(event.id)
    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("completed")
    expect(queue_event.metadata["status_reason"]).to eq("analysis_event_recorded")
  end

  it "marks stale queued analysis rows as failed when no queue job exists" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: { "story_id" => story_id }
    )
    event.media.attach(io: StringIO.new("one"), filename: "one.jpg", content_type: "image/jpeg")

    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { "story_id" => story_id, "status" => "queued" }
    )

    query = described_class.new(
      account: account,
      page: 1,
      per_page: 12,
      analysis_queue_inspector: instance_double(InstagramAccounts::StoryAnalysisQueueInspector, stale_job?: true)
    )
    result = query.call

    expect(result.events.map(&:id)).to include(event.id)
    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("failed")
    expect(queue_event.metadata["status_reason"]).to eq("stale_or_missing_job")
    expect(queue_event.metadata["error_message"]).to eq("Previous story analysis job appears stalled or missing.")
  end
end
