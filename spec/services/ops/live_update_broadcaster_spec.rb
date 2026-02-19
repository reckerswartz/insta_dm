require "rails_helper"

RSpec.describe Ops::LiveUpdateBroadcaster do
  describe ".broadcast!" do
    it "broadcasts to account stream only when account_id is present" do
      expect(ActionCable.server).to receive(:broadcast).with("operations:account:123", kind_of(Hash)).once
      expect(ActionCable.server).not_to receive(:broadcast).with("operations:global", anything)

      described_class.broadcast!(
        topic: "jobs_changed",
        account_id: 123,
        payload: { status: "started" },
        throttle_seconds: 0
      )
    end

    it "broadcasts to global stream when no account is provided" do
      expect(ActionCable.server).to receive(:broadcast).with("operations:global", kind_of(Hash)).once

      described_class.broadcast!(
        topic: "jobs_changed",
        payload: { status: "started" },
        throttle_seconds: 0
      )
    end

    it "can broadcast to both account and global streams when requested" do
      expect(ActionCable.server).to receive(:broadcast).with("operations:global", kind_of(Hash)).once
      expect(ActionCable.server).to receive(:broadcast).with("operations:account:42", kind_of(Hash)).once

      described_class.broadcast!(
        topic: "issues_changed",
        account_id: 42,
        include_global: true,
        payload: { status: "open" },
        throttle_seconds: 0
      )
    end
  end
end

