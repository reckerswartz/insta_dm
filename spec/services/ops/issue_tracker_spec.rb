require "rails_helper"
require "securerandom"

RSpec.describe Ops::IssueTracker do
  it "drops deleted account/profile ids before creating an app issue" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    deleted_account_id = account.id
    deleted_profile_id = profile.id
    InstagramProfile.where(id: profile.id).delete_all
    InstagramAccount.where(id: account.id).delete_all

    issue = described_class.send(
      :upsert_issue!,
      issue_type: "job_failure",
      source: "AutoEngageHomeFeedJob",
      severity: "error",
      title: "Job failure in AutoEngageHomeFeedJob",
      details: "Couldn't find InstagramAccount",
      metadata: {},
      fingerprint: SecureRandom.hex(16),
      instagram_account_id: deleted_account_id,
      instagram_profile_id: deleted_profile_id
    )

    expect(issue).to be_present
    expect(issue.instagram_account_id).to be_nil
    expect(issue.instagram_profile_id).to be_nil
  end
end
