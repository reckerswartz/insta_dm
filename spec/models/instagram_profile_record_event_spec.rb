require "rails_helper"
require "securerandom"

RSpec.describe InstagramProfile, type: :model do
  describe "#record_event!" do
    it "handles unique-index races by returning and updating the existing event" do
      account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
      existing_event = profile.instagram_profile_events.create!(
        kind: "story_uploaded",
        external_id: "story_uploaded:123",
        detected_at: 10.minutes.ago,
        metadata: { "source" => "initial" }
      )

      conflict_event = profile.instagram_profile_events.build(kind: "story_uploaded", external_id: "story_uploaded:123")
      allow(profile.instagram_profile_events).to receive(:find_or_initialize_by).and_return(conflict_event)
      allow(conflict_event).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

      now = Time.current.change(usec: 0)
      returned_event = profile.record_event!(
        kind: "story_uploaded",
        external_id: "story_uploaded:123",
        occurred_at: now,
        metadata: { source: "retry", attempts: 2 }
      )

      expect(returned_event.id).to eq(existing_event.id)
      existing_event.reload
      expect(existing_event.detected_at).to be_present
      expect(existing_event.occurred_at.to_i).to eq(now.to_i)
      expect(existing_event.metadata).to include(
        "source" => "retry",
        "attempts" => 2
      )
    end
  end
end
