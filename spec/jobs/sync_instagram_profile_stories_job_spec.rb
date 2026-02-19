require "rails_helper"
require "securerandom"

RSpec.describe "SyncInstagramProfileStoriesJobTest" do
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
    allow_any_instance_of(SyncInstagramProfileStoriesJob).to receive(:analyze_story_for_comments).and_return({ ok: false })
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
