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
    expect(downloaded_event.reload.llm_comment_status).not_to eq("queued")
  end
end
