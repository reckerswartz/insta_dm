require "rails_helper"

RSpec.describe Messaging::IntegrationService, :vcr do
  it "sends a request against a recorded third-party endpoint response" do
    service = Messaging::IntegrationService.new(
      api_url: "https://httpbin.org/anything",
      access_token: ENV.fetch("OFFICIAL_MESSAGING_API_TOKEN", "test_token")
    )

    result = service.send_text!(
      recipient_id: "recipient_123",
      text: "hello from rspec",
      context: { source: "vcr_spec" }
    )

    expect(result[:ok]).to eq(true)
    expect(result[:status]).to eq(200)
  end
end
