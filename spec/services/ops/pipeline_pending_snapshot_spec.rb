require "rails_helper"
require "securerandom"

RSpec.describe Ops::PipelinePendingSnapshot do
  describe ".snapshot" do
    it "builds pending post and story backlog snapshots with reason rows and ETA" do
      account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")

      profile.instagram_profile_posts.create!(
        instagram_account: account,
        shortcode: "pending_#{SecureRandom.hex(2)}",
        taken_at: 1.hour.ago,
        ai_status: "running",
        ai_pipeline_run_id: "post-run-1",
        ai_blocking_step: "visual",
        ai_pending_reason_code: "queued_visual",
        ai_pending_since_at: 6.minutes.ago,
        ai_next_retry_at: 2.minutes.from_now,
        ai_estimated_ready_at: 4.minutes.from_now
      )

      profile.instagram_profile_events.create!(
        kind: "story_downloaded",
        external_id: "evt_#{SecureRandom.hex(4)}",
        detected_at: Time.current,
        occurred_at: Time.current,
        llm_comment_status: "running",
        llm_pipeline_run_id: "story-run-1",
        llm_blocking_step: "ocr_analysis",
        llm_pending_reason_code: "queued_ocr_analysis",
        llm_estimated_ready_at: 3.minutes.from_now,
        metadata: { "story_id" => "story_123" }
      )

      snapshot = described_class.snapshot(use_cache: false)

      expect(snapshot.dig(:posts, :pending_total)).to be >= 1
      expect(snapshot.dig(:posts, :running_total)).to be >= 1
      expect(snapshot.dig(:story_events, :pending_total)).to be >= 1
      expect(snapshot.dig(:story_events, :running_total)).to be >= 1

      post_reason = Array(snapshot.dig(:posts, :reasons)).find { |row| row[:reason_code] == "queued_visual" }
      expect(post_reason).to include(reason_code: "queued_visual", blocking_step: "visual")
      expect(post_reason[:count]).to be >= 1

      story_reason = Array(snapshot.dig(:story_events, :reasons)).find { |row| row[:reason_code] == "queued_ocr_analysis" }
      expect(story_reason).to include(reason_code: "queued_ocr_analysis")
      expect(story_reason[:count]).to be >= 1

      post_item = Array(snapshot.dig(:posts, :items)).find { |row| row[:pipeline_run_id] == "post-run-1" }
      expect(post_item).to include(
        pipeline_run_id: "post-run-1",
        blocking_step: "visual",
        pending_reason_code: "queued_visual",
        status: "running"
      )
      expect(post_item[:eta_seconds]).to be > 0
      expect(post_item[:pending_age_seconds]).to be > 0

      story_item = Array(snapshot.dig(:story_events, :items)).find { |row| row[:pipeline_run_id] == "story-run-1" }
      expect(story_item).to include(
        pipeline_run_id: "story-run-1",
        blocking_step: "ocr_analysis",
        pending_reason_code: "queued_ocr_analysis",
        status: "running",
        story_id: "story_123"
      )
      expect(story_item[:eta_seconds]).to be > 0
    end

    it "filters rows by account when account_id is provided" do
      account_one = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      profile_one = account_one.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
      account_two = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      profile_two = account_two.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")

      profile_one.instagram_profile_posts.create!(
        instagram_account: account_one,
        shortcode: "a1_#{SecureRandom.hex(2)}",
        taken_at: Time.current,
        ai_status: "pending",
        ai_pending_reason_code: "waiting_visual",
        ai_estimated_ready_at: 4.minutes.from_now
      )
      profile_two.instagram_profile_posts.create!(
        instagram_account: account_two,
        shortcode: "a2_#{SecureRandom.hex(2)}",
        taken_at: Time.current,
        ai_status: "pending",
        ai_pending_reason_code: "waiting_video",
        ai_estimated_ready_at: 4.minutes.from_now
      )

      profile_one.instagram_profile_events.create!(
        kind: "story_downloaded",
        external_id: "evt_#{SecureRandom.hex(4)}",
        detected_at: Time.current,
        llm_comment_status: "queued",
        llm_pending_reason_code: "queued_llm_generation",
        llm_estimated_ready_at: 2.minutes.from_now
      )
      profile_two.instagram_profile_events.create!(
        kind: "story_downloaded",
        external_id: "evt_#{SecureRandom.hex(4)}",
        detected_at: Time.current,
        llm_comment_status: "queued",
        llm_pending_reason_code: "queued_ocr_analysis",
        llm_estimated_ready_at: 2.minutes.from_now
      )

      snapshot = described_class.snapshot(account_id: account_one.id, use_cache: false)

      expect(snapshot[:account_id]).to eq(account_one.id)
      expect(snapshot.dig(:posts, :pending_total)).to eq(1)
      expect(snapshot.dig(:story_events, :pending_total)).to eq(1)
      expect(snapshot.dig(:posts, :items).map { |row| row[:profile_username] }).to all(eq(profile_one.username))
      expect(snapshot.dig(:story_events, :items).map { |row| row[:profile_username] }).to all(eq(profile_one.username))
    end
  end
end
