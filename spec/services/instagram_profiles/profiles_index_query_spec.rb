require "rails_helper"
require "securerandom"

RSpec.describe InstagramProfiles::ProfilesIndexQuery do
  it "applies search, boolean filters, and pagination" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    target = InstagramProfile.create!(
      instagram_account: account,
      username: "alice_#{SecureRandom.hex(3)}",
      display_name: "Alice Example",
      following: true,
      follows_you: true,
      can_message: true
    )
    InstagramProfile.create!(
      instagram_account: account,
      username: "bob_#{SecureRandom.hex(3)}",
      display_name: "Bob Example",
      following: true,
      follows_you: false,
      can_message: nil
    )

    params = ActionController::Parameters.new(
      q: "alice",
      mutual: "1",
      page: "1",
      per_page: "10"
    )

    result = described_class.new(account: account, params: params).call

    expect(result.q).to eq("alice")
    expect(result.filter).to include(mutual: true, following: nil, follows_you: nil, can_message: nil)
    expect(result.total).to eq(1)
    expect(result.pages).to eq(1)
    expect(result.profiles.map(&:id)).to eq([target.id])
  end

  it "supports tabulator remote sorting and unknown can_message filter" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    InstagramProfile.create!(instagram_account: account, username: "aaa_#{SecureRandom.hex(2)}", can_message: true)
    middle = InstagramProfile.create!(instagram_account: account, username: "mmm_#{SecureRandom.hex(2)}", can_message: nil)
    InstagramProfile.create!(instagram_account: account, username: "zzz_#{SecureRandom.hex(2)}", can_message: false)

    params = ActionController::Parameters.new(
      filters: [ { field: "can_message", value: "unknown" } ].to_json,
      sorters: [ { "field" => "username", "dir" => "desc" } ],
      per_page: 20
    )

    result = described_class.new(account: account, params: params).call

    expect(result.total).to eq(1)
    expect(result.profiles.map(&:id)).to eq([middle.id])
  end
end
