require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "Workspace::ActionsTodoQueueServiceTest" do
  before { Rails.cache.clear }

  it "builds queue items only for eligible user-created posts" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    person = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(3)}")
    post_ready = person.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "ready_#{SecureRandom.hex(2)}",
      taken_at: 2.hours.ago,
      ai_status: "analyzed",
      analysis: { "comment_suggestions" => [ "Nice shot", "Great frame" ] },
      metadata: { "post_kind" => "post" }
    )
    post_pending = person.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(2)}",
      taken_at: 1.hour.ago,
      ai_status: "pending",
      analysis: {},
      metadata: { "post_kind" => "post" }
    )

    page_profile = account.instagram_profiles.create!(username: "brand_page_#{SecureRandom.hex(2)}")
    page_tag = ProfileTag.find_or_create_by!(name: "page")
    page_profile.profile_tags << page_tag
    page_profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "page_#{SecureRandom.hex(2)}",
      taken_at: 30.minutes.ago,
      ai_status: "analyzed",
      analysis: { "comment_suggestions" => [ "should be skipped" ] },
      metadata: { "post_kind" => "post" }
    )

    person.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "story_#{SecureRandom.hex(2)}",
      taken_at: 20.minutes.ago,
      ai_status: "analyzed",
      analysis: { "comment_suggestions" => [ "story post" ] },
      metadata: { "post_kind" => "story" }
    )

    result = Workspace::ActionsTodoQueueService.new(account: account, limit: 20, enqueue_processing: false).fetch!

    shortcodes = Array(result[:items]).map { |item| item[:post].shortcode }
    assert_includes shortcodes, post_ready.shortcode
    assert_includes shortcodes, post_pending.shortcode
    refute shortcodes.any? { |code| code.start_with?("page_") }
    refute shortcodes.any? { |code| code.start_with?("story_") }

    ready_row = result[:items].find { |item| item[:post].id == post_ready.id }
    pending_row = result[:items].find { |item| item[:post].id == post_pending.id }

    assert_equal "ready", ready_row[:processing_status]
    assert_equal false, ready_row[:requires_processing]
    assert_equal "waiting_media_download", pending_row[:processing_status]
    assert_equal true, pending_row[:requires_processing]
  end

  it "excludes posts that already have a comment sent event" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(3)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "posted_#{SecureRandom.hex(2)}",
      taken_at: Time.current,
      ai_status: "analyzed",
      analysis: { "comment_suggestions" => [ "Looks good" ] },
      metadata: { "post_kind" => "post" }
    )

    profile.instagram_profile_events.create!(
      kind: "post_comment_sent",
      external_id: "comment_sent_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: { "post_shortcode" => post.shortcode, "comment_text" => "Looks good" }
    )

    result = Workspace::ActionsTodoQueueService.new(account: account, limit: 10, enqueue_processing: false).fetch!

    assert_equal 0, Array(result[:items]).length
    assert_equal 0, result[:stats][:total_items].to_i
  end

  it "marks blocked rows as waiting build history when evidence is incomplete" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(3)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "blocked_#{SecureRandom.hex(2)}",
      taken_at: Time.current,
      ai_status: "analyzed",
      analysis: {},
      metadata: {
        "post_kind" => "post",
        "comment_generation_policy" => {
          "status" => "blocked",
          "history_reason_code" => "latest_posts_not_analyzed",
          "blocked_reason_code" => "missing_required_evidence"
        }
      }
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

    result = Workspace::ActionsTodoQueueService.new(account: account, limit: 10, enqueue_processing: false).fetch!
    row = Array(result[:items]).find { |item| item[:post].id == post.id }

    assert_equal "waiting_build_history", row[:processing_status]
    assert_includes row[:processing_message], "Build History"
  end

  it "pauses enqueue when queue health is degraded" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(3)}")
    profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(2)}",
      taken_at: Time.current,
      ai_status: "pending",
      analysis: {},
      metadata: { "post_kind" => "post" }
    )

    allow(Ops::QueueHealth).to receive(:check!).and_return(
      { ok: false, reason: "no_workers_with_backlog", counts: { enqueued: 12, processes: 0 } }
    )
    expect(WorkspaceProcessActionsTodoPostJob).not_to receive(:enqueue_if_needed!)

    result = Workspace::ActionsTodoQueueService.new(account: account, limit: 10, enqueue_processing: true).fetch!

    assert_equal 0, result.dig(:stats, :enqueued_now).to_i
    assert_equal "no_workers_with_backlog", result.dig(:stats, :enqueue_blocked_reason)
  end

  it "enqueues when queue health is healthy" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(3)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "todo_#{SecureRandom.hex(2)}",
      taken_at: Time.current,
      ai_status: "pending",
      analysis: {},
      metadata: { "post_kind" => "post" }
    )

    allow(Ops::QueueHealth).to receive(:check!).and_return({ ok: true, counts: { processes: 2 } })
    expect(WorkspaceProcessActionsTodoPostJob).to receive(:enqueue_if_needed!).with(
      account: account,
      profile: profile,
      post: post,
      requested_by: "workspace_actions_queue"
    ).and_return({ enqueued: true })

    result = Workspace::ActionsTodoQueueService.new(account: account, limit: 10, enqueue_processing: true).fetch!

    assert_equal 1, result.dig(:stats, :enqueued_now).to_i
    assert_nil result.dig(:stats, :enqueue_blocked_reason)
  end
end
