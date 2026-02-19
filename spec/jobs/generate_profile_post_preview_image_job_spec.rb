require "rails_helper"
require "securerandom"

RSpec.describe "GenerateProfilePostPreviewImageJobTest" do
  it "attaches preview image and stamps metadata for a video profile post" do
    account = InstagramAccount.create!(username: "preview_job_acct_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "preview_job_profile_#{SecureRandom.hex(3)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "preview_job_shortcode_#{SecureRandom.hex(3)}",
      source_media_url: "https://cdn.example.com/source.mp4",
      metadata: { "media_type" => 2 }
    )
    post.media.attach(
      io: StringIO.new("....ftypisom....video".b),
      filename: "source.mp4",
      content_type: "video/mp4"
    )

    preview_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\xFF\xD8\xFF\xE0preview-jpeg".b),
      filename: "generated_preview.jpg",
      content_type: "image/jpeg"
    )
    preview_attachment = double("preview_attachment", attached?: true, blob: preview_blob)
    preview_representation = double("preview_representation")
    allow(preview_representation).to receive(:processed).and_return(preview_representation)
    allow(preview_representation).to receive(:image).and_return(preview_attachment)
    allow_any_instance_of(ActiveStorage::Blob)
      .to receive(:preview)
      .with(resize_to_limit: [ 640, 640 ])
      .and_return(preview_representation)

    GenerateProfilePostPreviewImageJob.perform_now(instagram_profile_post_id: post.id)

    post.reload
    assert post.preview_image.attached?
    assert_equal preview_blob.id, post.preview_image.blob.id
    assert_equal "attached", post.metadata["preview_image_status"]
    assert_equal "active_storage_preview_job", post.metadata["preview_image_source"]
    assert post.metadata["preview_image_attached_at"].present?
  end
end
