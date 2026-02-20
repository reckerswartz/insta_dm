require "rails_helper"
require "securerandom"

RSpec.describe InstagramProfile do
  it "defaults dm_auto_mode to draft_only and supports helper predicates" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = described_class.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )

    expect(profile.dm_auto_mode).to eq("draft_only")
    expect(profile.dm_draft_only?).to eq(true)
    expect(profile.dm_autonomous?).to eq(false)

    profile.update!(dm_auto_mode: "autonomous")
    expect(profile.dm_autonomous?).to eq(true)
    expect(profile.dm_draft_only?).to eq(false)
  end
end
