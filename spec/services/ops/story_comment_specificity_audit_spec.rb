require "rails_helper"
require "securerandom"

RSpec.describe Ops::StoryCommentSpecificityAudit do
  it "summarizes repeated anchors and fallback usage for selected story ids" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")

    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 2.minutes.ago,
      metadata: { "story_id" => "s_1", "media_content_type" => "video/mp4" },
      llm_comment_status: "completed",
      llm_generated_comment: "Love this car energy.",
      llm_comment_metadata: {
        "source" => "fallback",
        "generation_status" => "fallback_used",
        "generation_inputs" => {
          "selected_topics" => ["car"],
          "visual_anchors" => %w[car bench],
          "content_mode" => "general",
          "signal_score" => 2
        }
      }
    )

    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 1.minute.ago,
      metadata: { "story_id" => "s_2", "media_content_type" => "video/mp4" },
      llm_comment_status: "completed",
      llm_generated_comment: "This car moment feels real.",
      llm_comment_metadata: {
        "source" => "ollama",
        "generation_status" => "ok",
        "generation_inputs" => {
          "selected_topics" => ["car"],
          "visual_anchors" => %w[car bench],
          "content_mode" => "general",
          "signal_score" => 3
        }
      }
    )

    result = described_class.new(
      account_id: account.id,
      story_ids: "s_1, s_2",
      limit: 10,
      regenerate: false,
      wait: false
    ).call

    expect(result[:selected_count]).to eq(2)
    expect(result[:summary_before][:fallback_count]).to eq(1)
    expect(result[:summary_before][:repeated_anchor_signatures].values.max).to eq(2)
    expect(result[:comparisons].size).to eq(2)
    expect(result[:comparisons].all? { |row| Array(row[:changed_fields]).empty? }).to eq(true)
  end
end
