require "rails_helper"

RSpec.describe StoryArchive::MediaPreviewResolver do
  describe ".static_video_preview?" do
    it "returns true for static video source metadata" do
      metadata = { "processing_metadata" => { "source" => "video_static_single_frame" } }

      expect(described_class.static_video_preview?(metadata: metadata)).to be(true)
    end

    it "returns false when static signals are absent" do
      metadata = { "processing_metadata" => { "source" => "video_full_processing" } }

      expect(described_class.static_video_preview?(metadata: metadata)).to be(false)
    end
  end

  describe ".metadata_preview_image_url" do
    it "prefers direct image_url" do
      metadata = {
        "image_url" => "https://cdn.example/direct.jpg",
        "carousel_media" => [ { "image_url" => "https://cdn.example/carousel.jpg" } ]
      }

      expect(described_class.metadata_preview_image_url(metadata: metadata)).to eq("https://cdn.example/direct.jpg")
    end

    it "falls back to carousel media image url" do
      metadata = { "carousel_media" => [ { "image_url" => "https://cdn.example/carousel.jpg" } ] }

      expect(described_class.metadata_preview_image_url(metadata: metadata)).to eq("https://cdn.example/carousel.jpg")
    end
  end

  describe ".preferred_preview_image_url" do
    it "returns metadata-derived url when no preview attachment exists" do
      preview_attachment = instance_double("preview_attachment", attached?: false)
      event = instance_double("InstagramProfileEvent", preview_image: preview_attachment)
      metadata = { "image_url" => "https://cdn.example/story.jpg" }

      expect(described_class.preferred_preview_image_url(event: event, metadata: metadata)).to eq("https://cdn.example/story.jpg")
    end
  end
end
