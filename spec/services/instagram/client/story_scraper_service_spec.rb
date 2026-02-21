require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client::StoryScraperService do
  it "includes the extracted story sync modules" do
    expect(described_class.included_modules.map(&:name)).to include(
      "Instagram::Client::StoryScraper::HomeCarouselSync",
      "Instagram::Client::StoryScraper::CarouselOpening",
      "Instagram::Client::StoryScraper::CarouselNavigation"
    )
  end

  it "resolves story scraper entrypoints from extracted modules" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    expect(client).to respond_to(:sync_home_story_carousel!)
    expect(client.method(:sync_home_story_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::HomeCarouselSync")
    expect(client.method(:open_first_story_from_home_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselOpening")
    expect(client.method(:click_next_story_in_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselNavigation")
  end

  it "recovers a numeric story id from media URL hints when context id is missing" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    recovered = client.send(
      :resolve_story_id_for_processing,
      current_story_id: "",
      ref: "sample_user:",
      live_url: "https://www.instagram.com/stories/sample_user/",
      media: {
        url: "https://cdninstagram.example/media.jpg?ig_cache_key=MzgzNjg1MjIzODE2NTMzODc5Mg%3D%3D"
      }
    )

    expect(recovered).to eq("3836852238165338792")
  end

  it "marks api_story_media_unavailable as retryable when API is rate limited" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    payload = client.send(
      :story_sync_failure_metadata,
      reason: "api_story_media_unavailable",
      error: nil,
      story_id: "3836852238165338792",
      story_ref: "sample_user:3836852238165338792",
      story_url: "https://www.instagram.com/stories/sample_user/3836852238165338792/",
      api_rate_limited: true,
      api_failure_status: 429
    )

    expect(payload["retryable"] || payload[:retryable]).to eq(true)
    expect(payload["failure_category"] || payload[:failure_category]).to eq("throttled")
  end

  it "still downloads a story when reply is unavailable" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "story_user_#{SecureRandom.hex(3)}")
    client = Instagram::Client.new(account: account)
    driver = build_story_driver(url: "https://www.instagram.com/stories/#{profile.username}/123/")

    stub_story_sync_environment(client: client, driver: driver, account_profile: profile)
    allow(client).to receive(:find_story_network_profile).and_return(profile)
    allow(client).to receive(:current_story_context).and_return(
      {
        ref: "#{profile.username}:123",
        username: profile.username,
        story_id: "123",
        story_key: "#{profile.username}:123"
      }
    )
    allow(client).to receive(:normalized_story_context_for_processing).and_wrap_original { |_m, **kwargs| kwargs[:context] }
    allow(client).to receive(:resolve_story_media_with_retry).and_return(
      {
        media: {
          url: "https://cdn.example/story_123.jpg",
          media_type: "image",
          source: "api_reels_media",
          image_url: "https://cdn.example/story_123.jpg",
          video_url: nil,
          width: 1080,
          height: 1920,
          media_variant_count: 1,
          primary_media_source: "root",
          primary_media_index: 0,
          carousel_media: []
        },
        attempts: [ { attempt: 1, source: "api_reels_media", resolved: true } ]
      }
    )
    allow(client).to receive(:story_reply_capability_from_api).and_return(
      { known: true, reply_possible: false, reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
    )
    expect(client).not_to receive(:comment_on_story_via_api!)

    result = client.sync_home_story_carousel!(story_limit: 1, auto_reply_only: false)

    expect(result[:stories_visited]).to eq(1)
    expect(result[:downloaded]).to eq(1)
    expect(result[:skipped_unreplyable]).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_downloaded").count).to eq(1)
    reply_skip = profile.instagram_profile_events.where(kind: "story_reply_skipped").order(id: :desc).find do |event|
      event.metadata.is_a?(Hash) && event.metadata["reason"].to_s == "api_can_reply_false"
    end
    expect(reply_skip).to be_present
  end

  it "does not consume the fetch limit for unresolved story ids" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "story_user_#{SecureRandom.hex(3)}")
    client = Instagram::Client.new(account: account)
    driver = build_story_driver(url: "https://www.instagram.com/stories/#{profile.username}/")

    stub_story_sync_environment(client: client, driver: driver, account_profile: profile)
    allow(client).to receive(:find_story_network_profile).and_return(profile)
    allow(client).to receive(:current_story_context).and_return(
      {
        ref: "#{profile.username}:unknown",
        username: profile.username,
        story_id: "",
        story_key: "#{profile.username}:unknown"
      },
      {
        ref: "#{profile.username}:456",
        username: profile.username,
        story_id: "456",
        story_key: "#{profile.username}:456"
      }
    )
    allow(client).to receive(:normalized_story_context_for_processing).and_wrap_original { |_m, **kwargs| kwargs[:context] }
    allow(client).to receive(:resolve_story_media_with_retry).and_return(
      { media: {}, attempts: [ { attempt: 1, source: "api_unresolved", resolved: false } ] },
      {
        media: {
          url: "https://cdn.example/story_456.jpg",
          media_type: "image",
          source: "api_reels_media",
          image_url: "https://cdn.example/story_456.jpg",
          video_url: nil,
          width: 1080,
          height: 1920,
          media_variant_count: 1,
          primary_media_source: "root",
          primary_media_index: 0,
          carousel_media: []
        },
        attempts: [ { attempt: 1, source: "api_reels_media", resolved: true } ]
      }
    )
    allow(client).to receive(:story_reply_capability_from_api).and_return(
      { known: true, reply_possible: false, reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
    )
    allow(client).to receive(:click_next_story_in_carousel!).and_return(true, false)

    result = client.sync_home_story_carousel!(story_limit: 1, auto_reply_only: false)

    expect(result[:stories_visited]).to eq(1)
    expect(result[:failed]).to be >= 1
    expect(profile.instagram_profile_events.where(kind: "story_downloaded").count).to eq(1)
    unresolved_failure = profile.instagram_profile_events.where(kind: "story_sync_failed").order(id: :desc).find do |event|
      event.metadata.is_a?(Hash) && event.metadata["reason"].to_s == "story_id_unresolved"
    end
    expect(unresolved_failure).to be_present
  end

  it "retries context resolution after view gate acknowledgement and processes the story" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "story_user_#{SecureRandom.hex(3)}")
    client = Instagram::Client.new(account: account)
    driver = build_story_driver(url: "https://www.instagram.com/stories/#{profile.username}/")

    stub_story_sync_environment(client: client, driver: driver, account_profile: profile)
    allow(client).to receive(:find_story_network_profile).and_return(profile)
    allow(client).to receive(:current_story_context).and_return(
      {
        ref: "",
        username: profile.username,
        story_id: "",
        story_key: ""
      },
      {
        ref: "#{profile.username}:789",
        username: profile.username,
        story_id: "789",
        story_key: "#{profile.username}:789"
      }
    )
    allow(client).to receive(:normalized_story_context_for_processing).and_wrap_original { |_m, **kwargs| kwargs[:context] }
    allow(client).to receive(:click_story_view_gate_if_present!).and_return(
      { clicked: false, label: "", present: false, cleared: true, reason: "view_gate_not_present", prompt_text: "" },
      { clicked: true, label: "view story", present: false, cleared: true, reason: "view_gate_cleared", prompt_text: "view as test_user?" }
    )
    allow(client).to receive(:resolve_story_media_with_retry).and_return(
      {
        media: {
          url: "https://cdn.example/story_789.jpg",
          media_type: "image",
          source: "api_reels_media",
          image_url: "https://cdn.example/story_789.jpg",
          video_url: nil,
          width: 1080,
          height: 1920,
          media_variant_count: 1,
          primary_media_source: "root",
          primary_media_index: 0,
          carousel_media: []
        },
        attempts: [ { attempt: 1, source: "api_reels_media", resolved: true } ]
      }
    )
    allow(client).to receive(:story_reply_capability_from_api).and_return(
      { known: true, reply_possible: false, reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
    )

    result = client.sync_home_story_carousel!(story_limit: 1, auto_reply_only: false)

    expect(result[:stories_visited]).to eq(1)
    expect(result[:downloaded]).to eq(1)
    failure_reason = profile.instagram_profile_events.where(kind: "story_sync_failed").map { |event| event.metadata["reason"] }
    expect(failure_reason).not_to include("story_context_missing")
  end

  it "records an explicit skip reason when the view gate remains blocked" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "story_user_#{SecureRandom.hex(3)}")
    client = Instagram::Client.new(account: account)
    driver = build_story_driver(url: "https://www.instagram.com/stories/#{profile.username}/")

    stub_story_sync_environment(client: client, driver: driver, account_profile: profile)
    allow(client).to receive(:current_story_context).and_return(
      {
        ref: "",
        username: profile.username,
        story_id: "",
        story_key: ""
      },
      {
        ref: "",
        username: profile.username,
        story_id: "",
        story_key: ""
      }
    )
    allow(client).to receive(:normalized_story_context_for_processing).and_wrap_original { |_m, **kwargs| kwargs[:context] }
    allow(client).to receive(:click_story_view_gate_if_present!).and_return(
      { clicked: false, label: "", present: false, cleared: true, reason: "view_gate_not_present", prompt_text: "" },
      { clicked: false, label: "", present: true, cleared: false, reason: "view_gate_detected_no_click_target", prompt_text: "view as reckerswartz?" }
    )

    result = client.sync_home_story_carousel!(story_limit: 1, auto_reply_only: false)

    expect(result[:stories_visited]).to eq(0)
    failure = profile.instagram_profile_events.where(kind: "story_sync_failed").order(id: :desc).find do |event|
      event.metadata["reason"].to_s == "story_view_gate_not_cleared"
    end
    expect(failure).to be_present
    expect(failure.metadata["gate_reason"]).to eq("view_gate_detected_no_click_target")
    expect(failure.metadata["gate_present"]).to eq(true)
    expect(failure.metadata["reference_url"]).to be_present
  end

  def build_story_driver(url:)
    navigation = instance_double("SeleniumNavigation")
    driver = instance_double("SeleniumDriver")
    allow(driver).to receive(:navigate).and_return(navigation)
    allow(navigation).to receive(:to)
    allow(driver).to receive(:current_url).and_return(url)
    allow(driver).to receive(:title).and_return("Instagram")
    allow(driver).to receive(:page_source).and_return("<html><body>story</body></html>")
    driver
  end

  def stub_story_sync_environment(client:, driver:, account_profile:)
    allow(client).to receive(:with_recoverable_session).and_yield
    allow(client).to receive(:with_authenticated_driver).and_yield(driver)
    allow(client).to receive(:with_task_capture).and_yield
    allow(client).to receive(:wait_for)
    allow(client).to receive(:dismiss_common_overlays!)
    allow(client).to receive(:capture_task_html)
    allow(client).to receive(:open_first_story_from_home_carousel!).and_return(true)
    allow(client).to receive(:freeze_story_progress!)
    allow(client).to receive(:click_story_view_gate_if_present!).and_return(clicked: false, label: "")
    allow(client).to receive(:recover_story_url_context!)
    allow(client).to receive(:story_page_unavailable?).and_return(false)
    allow(client).to receive(:find_or_create_profile_for_auto_engagement!).and_return(account_profile)
    allow(client).to receive(:find_existing_story_download_for_profile).and_return(nil)
    allow(client).to receive(:detect_story_ad_context).and_return(
      ad_detected: false,
      reason: "",
      marker_text: "",
      signal_source: "",
      signal_confidence: "",
      debug_hint: ""
    )
    allow(client).to receive(:story_external_profile_link_context_from_api).and_return(
      known: false,
      has_external_profile_link: false,
      reason_code: nil,
      linked_username: "",
      linked_profile_url: "",
      marker_text: "",
      linked_targets: []
    )
    allow(client).to receive(:story_reply_capability_from_api).and_return(
      known: false,
      reply_possible: nil,
      reason_code: nil,
      status: "Unknown"
    )
    allow(client).to receive(:load_story_download_media_for_profile).and_return(nil)
    allow(client).to receive(:download_media_with_metadata).and_return(
      bytes: "image-bytes".b,
      content_type: "image/jpeg",
      filename: "story.jpg"
    )
    allow(client).to receive(:attach_download_to_event).and_return(true)
    allow(client).to receive(:story_already_replied?).and_return(found: false, matched_by: nil, matched_external_id: nil)
    allow(client).to receive(:evaluate_story_image_quality).and_return(skip: false, reason: nil, entropy: 6.3)
    allow(client).to receive(:build_auto_engagement_post_payload).and_return({})
    allow(client).to receive(:analyze_for_auto_engagement!).and_return(nil)
    allow(client).to receive(:generate_comment_suggestions_from_analysis!).and_return([ "hi there" ])
    allow(client).to receive(:profile_auto_reply_enabled?).and_return(true)
    allow(client).to receive(:check_story_reply_capability).and_return(
      reply_possible: true,
      reason_code: nil,
      status: "Reply available",
      marker_text: "",
      submission_reason: "reply_box_found"
    )
    allow(client).to receive(:react_to_story_if_available!).and_return(reacted: false, reason: "reaction_controls_not_found", marker_text: "")
    allow(client).to receive(:mark_profile_interaction_state!)
    allow(client).to receive(:click_next_story_in_carousel!).and_return(false)
    allow(InstagramProfileEvent).to receive(:broadcast_story_archive_refresh!)
  end
end
