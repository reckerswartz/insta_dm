require "rails_helper"

RSpec.describe Instagram::Client::MediaDownloadService do
  subject(:service) { described_class.new(base_url: "https://www.instagram.com") }

  it "blocks ad-marked URLs before making an HTTP request" do
    allow(service).to receive(:http_request)

    expect {
      service.call(url: "https://cdninstagram.example/story.jpg?_nc_ad=1", user_agent: "Mozilla/5.0")
    }.to raise_error(described_class::BlockedMediaSourceError, /ad_related_media_source/)
    expect(service).not_to have_received(:http_request)
  end

  it "blocks promotional redirect targets" do
    redirect = Net::HTTPFound.new("1.1", "302", "Found")
    redirect["location"] = "https://doubleclick.net/ad.jpg"
    allow(service).to receive(:http_request).and_return(redirect)

    expect {
      service.call(url: "https://cdninstagram.example/story.jpg", user_agent: "Mozilla/5.0")
    }.to raise_error(described_class::BlockedMediaSourceError, /promotional_media_host/)
  end

  it "blocks html promotional payloads returned from media URLs" do
    html = Net::HTTPOK.new("1.1", "200", "OK")
    html["content-type"] = "text/html; charset=utf-8"
    allow(html).to receive(:body).and_return("<!doctype html><html><body>promo</body></html>")
    allow(service).to receive(:http_request).and_return(html)

    expect {
      service.call(url: "https://cdninstagram.example/story.jpg", user_agent: "Mozilla/5.0")
    }.to raise_error(described_class::BlockedMediaSourceError, /html_payload/)
  end
end
