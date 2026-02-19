require "rails_helper"

RSpec.describe "AvatarUrlNormalizerTest" do
  it "returns nil for instagram placeholder relative path" do
    raw = "/static/images/profile/profile-pic-null_outline_56_light-4x.png/bc91e9cae98c.png"
    assert_nil Instagram::AvatarUrlNormalizer.normalize(raw)
  end
  it "normalizes protocol-relative url to https" do
    raw = "//scontent.cdninstagram.com/v/t51.2885-19/1234_n.jpg?stp=dst-jpg"
    normalized = Instagram::AvatarUrlNormalizer.normalize(raw)

    assert_equal "https://scontent.cdninstagram.com/v/t51.2885-19/1234_n.jpg?stp=dst-jpg", normalized
  end
  it "keeps valid absolute https url" do
    raw = "https://scontent.cdninstagram.com/v/t51.2885-19/example.jpg"
    assert_equal raw, Instagram::AvatarUrlNormalizer.normalize(raw)
  end
end
