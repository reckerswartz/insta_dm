require "rails_helper"
require "securerandom"

RSpec.describe Ops::AccountIssues do
  it "flags missing cookies, session, and auth snapshot data" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    issues = described_class.for(account)
    messages = issues.map { |row| row[:message] }

    expect(messages).to include("No cookies stored. Import cookies or run Manual Browser Login.")
    expect(messages).to include("Login state is 'not_authenticated'. Sync and messaging will likely fail.")
    expect(messages).to include("No user-agent saved. Manual login usually captures one; headless sessions can be less stable without it.")
    expect(messages).to include("No auth snapshot captured yet.")
    expect(messages).to include("No ig_app_id in auth snapshot. API fetches may rely on fallback headers.")
    expect(messages).to include("No sessionid cookie detected. Re-authenticate this account.")
  end

  it "returns no issues when account is cookie-authenticated with complete auth metadata" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      login_state: "authenticated",
      user_agent: "Mozilla/5.0"
    )
    account.cookies = [ { "name" => "sessionid", "value" => "ok" } ]
    account.auth_snapshot = {
      "captured_at" => 2.days.ago.iso8601,
      "ig_app_id" => "123456"
    }
    account.save!

    issues = described_class.for(account)

    expect(issues).to eq([])
  end

  it "warns when auth snapshot timestamp is not parseable" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      login_state: "authenticated",
      user_agent: "Mozilla/5.0"
    )
    account.cookies = [ { "name" => "csrftoken", "value" => "token" } ]
    account.auth_snapshot = {
      "captured_at" => "invalid-time",
      "ig_app_id" => ""
    }
    account.save!

    issues = described_class.for(account)
    messages = issues.map { |row| row[:message] }

    expect(messages).to include("Auth snapshot captured_at is not parseable.")
    expect(messages).to include("No ig_app_id in auth snapshot. API fetches may rely on fallback headers.")
    expect(messages).to include("No sessionid cookie detected. Re-authenticate this account.")
  end

  it "warns for stale auth bundle when account is not fully authenticated" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      login_state: "not_authenticated",
      user_agent: "Mozilla/5.0"
    )
    account.cookies = [ { "name" => "sessionid", "value" => "cookie" } ]
    account.auth_snapshot = {
      "captured_at" => 90.days.ago.iso8601,
      "ig_app_id" => "123456"
    }
    account.save!

    issues = described_class.for(account)
    stale_warning = issues.find { |row| row[:message].include?("Session bundle captured at") }

    expect(stale_warning).to be_present
    expect(stale_warning[:level]).to eq(:warn)
  end
end
