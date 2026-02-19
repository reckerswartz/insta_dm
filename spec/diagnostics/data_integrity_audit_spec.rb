require "rails_helper"
require "securerandom"

RSpec.describe "Data Integrity Diagnostics", :diagnostic do
  it "has no duplicate keys for high-value unique domains" do
    duplicate_groups = {
      instagram_profiles: InstagramProfile.group(:instagram_account_id, :username).having("COUNT(*) > 1").count,
      instagram_posts: InstagramPost.group(:instagram_account_id, :shortcode).having("COUNT(*) > 1").count,
      instagram_profile_posts: InstagramProfilePost.group(:instagram_profile_id, :shortcode).having("COUNT(*) > 1").count,
      instagram_profile_events: InstagramProfileEvent.group(:instagram_profile_id, :kind, :external_id).having("COUNT(*) > 1").count,
    }

    offenders = duplicate_groups.transform_values(&:size).select { |_key, count| count.positive? }
    expect(offenders).to be_empty, "Duplicate key groups detected: #{offenders.inspect}"
  end

  it "has no orphaned Active Storage attachments" do
    orphaned = ActiveStorage::Attachment.left_outer_joins(:blob).where(active_storage_blobs: { id: nil }).count
    expect(orphaned).to eq(0)
  end

  it "can read back newly attached media bytes for audit-owned entities" do
    account = InstagramAccount.create!(username: "integrity_media_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "integrity_profile_#{SecureRandom.hex(4)}")
    post = account.instagram_profile_posts.create!(
      instagram_profile: profile,
      shortcode: "integrity_shortcode_#{SecureRandom.hex(4)}",
      taken_at: Time.current,
      caption: "media integrity probe",
      ai_status: "analyzed",
    )

    payload = "diagnostic-media-payload"
    post.media.attach(
      io: StringIO.new(payload),
      filename: "integrity.jpg",
      content_type: "image/jpeg",
    )

    expect(post.media).to be_attached
    expect(post.media.download).to eq(payload)
  end
end
