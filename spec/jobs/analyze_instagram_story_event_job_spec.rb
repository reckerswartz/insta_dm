require "rails_helper"
require "securerandom"

RSpec.describe AnalyzeInstagramStoryEventJob do
  it "analyzes a downloaded story asynchronously and marks queue status completed" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(StoryIntelligence::AnalysisService).to receive(:analyze_story_for_comments).and_return(
      {
        ok: true,
        provider: "local_ai",
        model: "vision-v1",
        relevant: true,
        author_type: "personal_user",
        image_description: "A person at a cafe",
        comment_suggestions: [ "Looks fun!" ],
        generation_policy: {},
        ownership_classification: {}
      }
    )
    expect(Timeout).to receive(:timeout).with(described_class::ANALYSIS_TIMEOUT_SECONDS).and_call_original

    assert_enqueued_with(job: ReevaluateProfileContentJob) do
      assert_enqueued_with(job: GenerateLlmCommentJob) do
        described_class.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          story_id: story_id,
          story_payload: {
            story_id: story_id,
            media_type: "image",
            media_url: "https://cdn.example.com/story.jpg",
            image_url: "https://cdn.example.com/story.jpg"
          },
          downloaded_event_id: downloaded_event.id,
          auto_reply: false
        )
      end
    end

    analyzed_event = profile.instagram_profile_events.where(kind: "story_analyzed").order(id: :desc).first
    expect(analyzed_event).to be_present
    expect(analyzed_event.metadata["ai_provider"]).to eq("local_ai")
    expect(analyzed_event.metadata["llm_comment_auto_queued"]).to eq(true)
    expect(analyzed_event.metadata["llm_comment_queue_reason"]).to eq("queued")

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("completed")
    expect(queue_event.metadata["llm_comment_auto_queued"]).to eq(true)
    expect(queue_event.metadata["llm_comment_queue_reason"]).to eq("queued")
    expect(downloaded_event.reload.llm_comment_status).to eq("queued")
  end

  it "records reply queue outcome when auto-reply is enabled" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(StoryIntelligence::AnalysisService).to receive(:analyze_story_for_comments).and_return(
      {
        ok: true,
        provider: "local_ai",
        model: "vision-v1",
        relevant: true,
        author_type: "personal_user",
        image_description: "A person at a cafe",
        comment_suggestions: [ "Looks fun!" ],
        generation_policy: {},
        ownership_classification: {}
      }
    )
    allow_any_instance_of(StoryIntelligence::AnalysisService).to receive(:story_reply_decision).and_return(
      { queue: true, reason: "eligible_for_reply" }
    )
    expect_any_instance_of(StoryIntelligence::AnalysisService).to receive(:queue_story_reply!).and_return(true)

    assert_enqueued_with(job: GenerateLlmCommentJob) do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        story_payload: {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story.jpg",
          image_url: "https://cdn.example.com/story.jpg"
        },
        downloaded_event_id: downloaded_event.id,
        auto_reply: true
      )
    end

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("completed")
    expect(queue_event.metadata["llm_comment_auto_queued"]).to eq(true)
    expect(queue_event.metadata["llm_comment_queue_reason"]).to eq("queued")
    expect(queue_event.metadata["reply_queued"]).to eq(true)
    expect(queue_event.metadata["reply_decision_reason"]).to eq("eligible_for_reply")
  end

  it "re-enqueues analysis when downloaded story media is not attached yet" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    expect_any_instance_of(StoryIntelligence::AnalysisService).not_to receive(:analyze_story_for_comments)

    assert_enqueued_with(job: described_class) do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        story_payload: { story_id: story_id, media_type: "image" },
        downloaded_event_id: downloaded_event.id,
        auto_reply: false
      )
    end

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("queued")
    expect(queue_event.metadata["status_reason"]).to eq("downloaded_story_media_missing")
    expect(queue_event.metadata["waiting_for_media_attachment"]).to eq(true)
    expect(queue_event.metadata["media_wait_attempt"]).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_analyzed")).to be_empty
    expect(profile.instagram_profile_events.where(kind: "story_analysis_failed")).to be_empty
  end

  it "marks analysis failed after media wait retries are exhausted" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    enqueued_before = enqueued_jobs.count
    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: story_id,
      story_payload: { story_id: story_id, media_type: "image" },
      downloaded_event_id: downloaded_event.id,
      auto_reply: false,
      media_wait_attempt: described_class::MEDIA_WAIT_MAX_ATTEMPTS
    )
    followup = enqueued_jobs.drop(enqueued_before).select { |row| row[:job] == described_class }
    expect(followup).to be_empty

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("failed")
    expect(queue_event.metadata["failure_reason"]).to eq("downloaded_story_media_missing")

    failed_event = profile.instagram_profile_events.where(kind: "story_analysis_failed").order(id: :desc).first
    expect(failed_event).to be_present
    expect(failed_event.metadata["failure_reason"]).to eq("downloaded_story_media_missing")
    expect(failed_event.metadata["downloaded_event_id"]).to eq(downloaded_event.id)
  end

  it "re-enqueues when another story analysis is already running" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(described_class).to receive(:claim_story_analysis_lock!).and_return(false)
    expect_any_instance_of(StoryIntelligence::AnalysisService).not_to receive(:analyze_story_for_comments)

    assert_enqueued_with(job: described_class) do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: story_id,
        story_payload: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" },
        downloaded_event_id: downloaded_event.id,
        auto_reply: false
      )
    end

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("queued")
    expect(queue_event.metadata["status_reason"]).to eq("active_story_analysis_running")
    expect(queue_event.metadata["waiting_for_analysis_lock"]).to eq(true)
    expect(queue_event.metadata["analysis_lock_wait_attempt"]).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_analyzed")).to be_empty
  end

  it "fails story analysis when lock wait retries are exhausted" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(described_class).to receive(:claim_story_analysis_lock!).and_return(false)
    expect_any_instance_of(StoryIntelligence::AnalysisService).not_to receive(:analyze_story_for_comments)

    enqueued_before = enqueued_jobs.count
    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: story_id,
      story_payload: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" },
      downloaded_event_id: downloaded_event.id,
      auto_reply: false,
      analysis_lock_wait_attempt: described_class::ANALYSIS_LOCK_WAIT_MAX_ATTEMPTS
    )
    followup = enqueued_jobs.drop(enqueued_before).select { |row| row[:job] == described_class }
    expect(followup).to be_empty

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("failed")
    expect(queue_event.metadata["failure_reason"]).to eq("analysis_lock_wait_timeout")
    expect(queue_event.metadata["waiting_for_analysis_lock"]).to eq(false)

    failed_event = profile.instagram_profile_events.where(kind: "story_analysis_failed").order(id: :desc).first
    expect(failed_event).to be_present
    expect(failed_event.metadata["failure_reason"]).to eq("analysis_lock_wait_timeout")
  end

  it "does not auto-queue llm comment generation when verified policy blocks comments" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(StoryIntelligence::AnalysisService).to receive(:analyze_story_for_comments).and_return(
      {
        ok: true,
        provider: "local_ai",
        model: "vision-v1",
        relevant: true,
        author_type: "personal_user",
        image_description: "A person at a cafe",
        comment_suggestions: [ "Looks fun!" ],
        generation_policy: { allow_comment: false, reason_code: "third_party_content" },
        ownership_classification: { label: "third_party_content" }
      }
    )

    enqueued_before = enqueued_jobs.count
    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: story_id,
      story_payload: {
        story_id: story_id,
        media_type: "image",
        media_url: "https://cdn.example.com/story.jpg",
        image_url: "https://cdn.example.com/story.jpg"
      },
      downloaded_event_id: downloaded_event.id,
      auto_reply: false
    )
    generated_jobs = enqueued_jobs.drop(enqueued_before).select { |row| row[:job] == GenerateLlmCommentJob }
    expect(generated_jobs).to be_empty

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("completed")
    expect(queue_event.metadata["llm_comment_auto_queued"]).to eq(false)
    expect(queue_event.metadata["llm_comment_queue_reason"]).to eq("third_party_content")
    downloaded_event.reload
    expect(downloaded_event.llm_comment_status).to eq("skipped")
    expect(downloaded_event.llm_comment_last_error).to be_present
    expect(downloaded_event.llm_comment_metadata["last_failure"]).to include(
      "reason" => "third_party_content",
      "source" => "validated_story_policy"
    )
  end

  it "records detailed failure reason when story analysis result is unavailable" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    story_id = "story_#{SecureRandom.hex(4)}"

    downloaded_event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{story_id}",
      metadata: { story_id: story_id, media_type: "image", media_url: "https://cdn.example.com/story.jpg" }
    )
    downloaded_event.media.attach(
      io: StringIO.new("story-bytes"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )
    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: { story_id: story_id, status: "queued" }
    )

    allow_any_instance_of(StoryIntelligence::AnalysisService).to receive(:analyze_story_for_comments).and_return(
      {
        ok: false,
        failure_reason: "analysis_error",
        error_class: "VisionModelError",
        error_message: "Vision worker unavailable"
      }
    )

    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: story_id,
      story_payload: {
        story_id: story_id,
        media_type: "image",
        media_url: "https://cdn.example.com/story.jpg",
        image_url: "https://cdn.example.com/story.jpg"
      },
      downloaded_event_id: downloaded_event.id,
      auto_reply: false
    )

    queue_event.reload
    expect(queue_event.metadata["status"]).to eq("failed")
    expect(queue_event.metadata["failure_reason"]).to eq("analysis_error")
    expect(queue_event.metadata["error_message"]).to eq("Vision worker unavailable")

    failed_event = profile.instagram_profile_events.where(kind: "story_analysis_failed").order(id: :desc).first
    expect(failed_event).to be_present
    expect(failed_event.metadata["failure_reason"]).to eq("analysis_error")
    expect(failed_event.metadata["error_message"]).to eq("Vision worker unavailable")
  end
end
