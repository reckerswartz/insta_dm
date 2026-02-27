require "rails_helper"
require "securerandom"

RSpec.describe "SyncInstagramProfileStoriesJobTest" do
  it "stores story_downloaded events with deterministic external_id per story" do
    account = InstagramAccount.create!(username: "story_ext_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_ext_profile_#{SecureRandom.hex(4)}")
    story_id = "3834712783221666503"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story.jpg",
          image_url: "https://cdn.example.com/story.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_return([ "bytes", "image/jpeg", "story.jpg" ])

    assert_enqueued_with(job: AnalyzeInstagramStoryEventJob) do
      with_client_stub(client_stub) do
        SyncInstagramProfileStoriesJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          max_stories: 1
        )
      end
    end

    event = profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    expect(event.external_id).to eq("story_downloaded:#{story_id}")
  end

  it "queues story preview generation for downloaded video stories" do
    account = InstagramAccount.create!(username: "story_video_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_video_profile_#{SecureRandom.hex(4)}")
    story_id = "video_story_#{SecureRandom.hex(3)}"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "video",
          media_url: "https://cdn.example.com/story.mp4",
          image_url: "https://cdn.example.com/story_preview.jpg",
          video_url: "https://cdn.example.com/story.mp4",
          primary_media_source: "api_video_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_return([ "video-bytes", "video/mp4", "story.mp4" ])

    assert_enqueued_with(job: GenerateStoryPreviewImageJob) do
      with_client_stub(client_stub) do
        SyncInstagramProfileStoriesJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          max_stories: 1
        )
      end
    end

    downloaded_event = profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    expect(downloaded_event).to be_present
    expect(downloaded_event.metadata["preview_image_status"]).to eq("queued")
    expect(downloaded_event.metadata["preview_image_queue_name"]).to eq("story_preview_generation")
  end

  it "does not requeue preview generation after permanent invalid video stream failure" do
    account = InstagramAccount.create!(username: "story_video_failed_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_video_failed_profile_#{SecureRandom.hex(4)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:failed_#{SecureRandom.hex(3)}",
      detected_at: Time.current,
      metadata: {
        "story_id" => "failed_preview_story",
        "preview_image_status" => "failed",
        "preview_image_failure_reason" => "invalid_video_stream"
      }
    )
    event.media.attach(
      io: StringIO.new("....ftypisom....video".b),
      filename: "failed_story.mp4",
      content_type: "video/mp4"
    )

    job = SyncInstagramProfileStoriesJob.new
    expect(GenerateStoryPreviewImageJob).not_to receive(:perform_later)

    result = job.send(
      :enqueue_story_preview_generation!,
      event: event,
      story: { story_id: "failed_preview_story" },
      user_agent: "spec-user-agent"
    )

    expect(result).to eq(false)
  end

  it "reuses saved story media across accounts by story_id before downloading" do
    source_account = InstagramAccount.create!(username: "story_src_#{SecureRandom.hex(4)}")
    source_profile = source_account.instagram_profiles.create!(username: "story_src_profile_#{SecureRandom.hex(4)}")
    source_story = InstagramStory.create!(
      instagram_account: source_account,
      instagram_profile: source_profile,
      story_id: "shared_story_1",
      media_type: "image",
      taken_at: 5.minutes.ago
    )
    source_story.media.attach(
      io: StringIO.new("cached-story-media"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )

    target_account = InstagramAccount.create!(username: "story_dst_#{SecureRandom.hex(4)}")
    target_profile = target_account.instagram_profiles.create!(username: "story_dst_profile_#{SecureRandom.hex(4)}")

    dataset = {
      profile: { display_name: target_profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: "shared_story_1",
          media_type: "image",
          media_url: "https://cdn.example.com/story-should-not-download.jpg",
          image_url: "https://cdn.example.com/story-should-not-download.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 1,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: target_profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{target_profile.username}/shared_story_1/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    expect_any_instance_of(SyncInstagramProfileStoriesJob).not_to receive(:download_story_media)

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: target_account.id,
        instagram_profile_id: target_profile.id,
        max_stories: 1
      )
    end

    downloaded_event = target_profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    assert_not_nil downloaded_event
    assert downloaded_event.media.attached?
    assert_equal true, ActiveModel::Type::Boolean.new.cast(downloaded_event.metadata["reused_local_cache"])
    assert_equal source_story.media.blob.id, downloaded_event.media.blob.id
  end

  it "reuses media from existing instagram_stories in the same profile before downloading" do
    account = InstagramAccount.create!(username: "story_local_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_local_profile_#{SecureRandom.hex(4)}")
    existing_story = InstagramStory.create!(
      instagram_account: account,
      instagram_profile: profile,
      story_id: "shared_local_story_1",
      media_type: "image",
      taken_at: 2.minutes.ago
    )
    existing_story.media.attach(
      io: StringIO.new("local-cached-story-media"),
      filename: "story_local.jpg",
      content_type: "image/jpeg"
    )

    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: "shared_local_story_1",
          media_type: "image",
          media_url: "https://cdn.example.com/story-should-not-download.jpg",
          image_url: "https://cdn.example.com/story-should-not-download.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 1,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/shared_local_story_1/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    expect_any_instance_of(SyncInstagramProfileStoriesJob).not_to receive(:download_story_media)

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1,
        force_analyze_all: true
      )
    end

    downloaded_event = profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    assert_not_nil downloaded_event
    assert downloaded_event.media.attached?
    assert_equal existing_story.media.blob.id, downloaded_event.media.blob.id
    assert_equal true, ActiveModel::Type::Boolean.new.cast(downloaded_event.metadata["reused_local_cache"])
    assert_equal "instagram_story_same_profile", downloaded_event.metadata["reused_local_cache_source"]
  end

  it "does not skip a story when only story_uploaded exists without a successful download" do
    account = InstagramAccount.create!(username: "story_retry_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_retry_profile_#{SecureRandom.hex(4)}")
    story_id = "3834712783221666504"

    profile.record_event!(
      kind: "story_uploaded",
      external_id: "story_uploaded:#{story_id}",
      occurred_at: 5.minutes.ago,
      metadata: { story_id: story_id }
    )

    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story_retry.jpg",
          image_url: "https://cdn.example.com/story_retry.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_return([ "bytes", "image/jpeg", "story.jpg" ])

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1
      )
    end

    downloaded_event = profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    expect(downloaded_event).to be_present
  end

  it "skips story media download when story media URL is promotional" do
    account = InstagramAccount.create!(username: "story_promo_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_promo_profile_#{SecureRandom.hex(4)}")
    story_id = "story_promo_#{SecureRandom.hex(4)}"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story.jpg?campaign_id=400",
          image_url: "https://cdn.example.com/story.jpg?campaign_id=400",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    expect_any_instance_of(SyncInstagramProfileStoriesJob).not_to receive(:download_story_media)

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1
      )
    end

    downloaded_event = profile.instagram_profile_events.where(kind: "story_downloaded").order(id: :desc).first
    expect(downloaded_event).to be_nil
    skipped_event = profile.instagram_profile_events.where(kind: "story_skipped_debug").order(id: :desc).first
    expect(skipped_event).to be_present
    expect(skipped_event.metadata["skip_reason"]).to eq("promotional_media_query")
  end

  it "does not enqueue analysis when story media attachment fails" do
    account = InstagramAccount.create!(username: "story_attach_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_attach_profile_#{SecureRandom.hex(4)}")
    story_id = "3834712783221666506"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story_attach_fail.jpg",
          image_url: "https://cdn.example.com/story_attach_fail.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_return([ "bytes", "image/jpeg", "story.jpg" ])
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:attach_media_to_event).and_return(nil)

    enqueued_before = enqueued_jobs.count
    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1
      )
    end

    generated_jobs = enqueued_jobs.drop(enqueued_before).select { |row| row[:job] == AnalyzeInstagramStoryEventJob }
    expect(generated_jobs).to be_empty

    failed_event = profile.instagram_profile_events.where(kind: "story_sync_failed").order(id: :desc).first
    expect(failed_event).to be_present
    expect(failed_event.metadata["reason"]).to eq("story_media_attach_failed")
    expect(failed_event.metadata["failure_category"]).to eq("media_attach")
  end

  it "marks stale queued story analysis events as failed so they can be re-queued" do
    account = InstagramAccount.create!(username: "story_stale_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_stale_profile_#{SecureRandom.hex(4)}")
    story_id = "story_stale_#{SecureRandom.hex(4)}"
    event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: {
        story_id: story_id,
        status: "queued",
        active_job_id: "missing-job-id",
        status_updated_at: 30.minutes.ago.iso8601
      }
    )

    inspector = instance_double(InstagramAccounts::StoryAnalysisQueueInspector, stale_job?: true)
    job = SyncInstagramProfileStoriesJob.new
    allow(job).to receive(:story_analysis_queue_inspector).and_return(inspector)

    result = job.send(:story_analysis_already_queued?, profile: profile, story_id: story_id)
    expect(result).to eq(false)

    event.reload
    expect(event.metadata["status"]).to eq("failed")
    expect(event.metadata["status_reason"]).to eq("stale_or_missing_job")
    expect(event.metadata["error_message"]).to include("stalled or missing")
  end

  it "keeps queued story analysis events blocked when they are still active" do
    account = InstagramAccount.create!(username: "story_active_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_active_profile_#{SecureRandom.hex(4)}")
    story_id = "story_active_#{SecureRandom.hex(4)}"
    event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: {
        story_id: story_id,
        status: "queued",
        active_job_id: "active-job-id",
        status_updated_at: 1.minute.ago.iso8601
      }
    )

    inspector = instance_double(InstagramAccounts::StoryAnalysisQueueInspector, stale_job?: false)
    job = SyncInstagramProfileStoriesJob.new
    allow(job).to receive(:story_analysis_queue_inspector).and_return(inspector)

    result = job.send(:story_analysis_already_queued?, profile: profile, story_id: story_id)
    expect(result).to eq(true)

    event.reload
    expect(event.metadata["status"]).to eq("queued")
  end

  it "records categorized story_sync_failed details when a story media download fails" do
    account = InstagramAccount.create!(username: "story_fail_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_fail_profile_#{SecureRandom.hex(4)}")
    story_id = "3834712783221666505"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story_fail.jpg",
          image_url: "https://cdn.example.com/story_fail.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_raise(RuntimeError, "Invalid media URL")

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1
      )
    end

    failed_event = profile.instagram_profile_events.where(kind: "story_sync_failed").order(id: :desc).first
    expect(failed_event).to be_present
    expect(failed_event.metadata["failure_category"]).to eq("media_fetch")
    expect(failed_event.metadata["reason"]).to eq("media_download_or_validation_failed")
    expect(failed_event.metadata["retryable"]).to eq(false)
  end

  it "updates profile and account last_synced_at on successful sync completion" do
    account = InstagramAccount.create!(username: "story_sync_ts_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_sync_ts_profile_#{SecureRandom.hex(4)}")
    story_id = "story_sync_ts_#{SecureRandom.hex(4)}"
    dataset = {
      profile: { display_name: profile.username, profile_pic_url: nil, ig_user_id: nil, bio: nil, last_post_at: nil },
      stories: [
        {
          story_id: story_id,
          media_type: "image",
          media_url: "https://cdn.example.com/story_sync_ts.jpg",
          image_url: "https://cdn.example.com/story_sync_ts.jpg",
          video_url: nil,
          primary_media_source: "api_image_versions",
          primary_media_index: 0,
          media_variants: [],
          carousel_media: [],
          can_reply: true,
          can_reshare: true,
          owner_user_id: nil,
          owner_username: profile.username,
          api_has_external_profile_indicator: false,
          api_external_profile_reason: nil,
          api_external_profile_targets: [],
          api_should_skip: false,
          caption: nil,
          permalink: "https://www.instagram.com/stories/#{profile.username}/#{story_id}/",
          taken_at: Time.current,
          expiring_at: 12.hours.from_now
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) { |**_kwargs| dataset }

    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:capture_story_html_snapshot)
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:download_story_media).and_return([ "bytes", "image/jpeg", "story.jpg" ])

    with_client_stub(client_stub) do
      SyncInstagramProfileStoriesJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        max_stories: 1
      )
    end

    expect(profile.reload.last_synced_at).to be_present
    expect(account.reload.last_synced_at).to be_present
  end

  private

  def with_client_stub(stubbed_client)
    singleton = class << Instagram::Client; self; end
    singleton.class_eval do
      alias_method :__story_sync_test_original_new, :new
      define_method(:new) { |**_kwargs| stubbed_client }
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :new, :__story_sync_test_original_new
      remove_method :__story_sync_test_original_new
    end
  end
end
