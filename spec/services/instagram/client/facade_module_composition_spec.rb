require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client do
  describe "facade composition" do
    it "resolves private workflows from extracted support modules" do
      account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      client = described_class.new(account: account)

      expect(client.method(:auto_engage_first_story!).owner.name).to eq("Instagram::Client::AutoEngagementSupport")
      expect(client.method(:find_home_story_open_target).owner.name).to eq("Instagram::Client::StoryNavigationSupport")
      expect(client.method(:download_media_with_metadata).owner.name).to eq("Instagram::Client::MediaDownloadSupport")
      expect(client.method(:comment_on_story_via_api!).owner.name).to eq("Instagram::Client::StoryInteractionSupport")
      expect(client.method(:detect_story_ad_context).owner.name).to eq("Instagram::Client::StorySignalSupport")
      expect(client.method(:logged_out_page?).owner.name).to eq("Instagram::Client::BrowserStateSupport")
    end

    it "delegates media download to MediaDownloadService" do
      account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
      client = described_class.new(account: account)
      service = instance_double(Instagram::Client::MediaDownloadService)
      result = { bytes: "data", content_type: "image/jpeg", filename: "f.jpg", final_url: "https://example.com/f.jpg" }

      allow(client).to receive(:media_download_service).and_return(service)
      allow(service).to receive(:call).and_return(result)

      response = client.send(
        :download_media_with_metadata,
        url: "https://example.com/f.jpg",
        user_agent: "ua",
        redirect_limit: 1
      )

      expect(response).to eq(result)
      expect(service).to have_received(:call).with(url: "https://example.com/f.jpg", user_agent: "ua", redirect_limit: 1)
    end
  end
end
