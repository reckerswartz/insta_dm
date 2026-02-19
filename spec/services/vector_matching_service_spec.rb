require "rails_helper"
require "securerandom"

RSpec.describe "VectorMatchingServiceTest" do
  it "does not double count repeated observation signatures" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")

    service = VectorMatchingService.new(threshold: 0.7)
    first = service.match_or_create!(
      account: account,
      profile: profile,
      embedding: [ 0.91, 0.12, 0.21 ],
      observation_signature: "post:10:face:0"
    )

    second = service.match_or_create!(
      account: account,
      profile: profile,
      embedding: [ 0.91, 0.12, 0.21 ],
      observation_signature: "post:10:face:0"
    )

    third = service.match_or_create!(
      account: account,
      profile: profile,
      embedding: [ 0.91, 0.12, 0.21 ],
      observation_signature: "post:11:face:0"
    )

    person = first[:person]
    person.reload

    assert_equal false, first[:matched]
    assert_equal true, second[:matched]
    assert_equal person.id, second[:person].id
    assert_equal true, third[:matched]
    assert_equal person.id, third[:person].id
    assert_equal 2, person.appearance_count
    assert_equal [ "post:10:face:0", "post:11:face:0" ], Array(person.metadata["observation_signatures"])
  end
end
