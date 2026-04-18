require "rails_helper"
require "playwright"

RSpec.describe Instagram::Client::SessionRecoverySupport do
  let(:client) do
    account = InstagramAccount.create!(username: "sr_#{SecureRandom.hex(4)}")
    Instagram::Client.new(account: account)
  end

  describe "#disconnected_session_error?" do
    it "detects the legacy Selenium InvalidSessionIdError class" do
      err = Selenium::WebDriver::Error::InvalidSessionIdError.new("invalid session id")
      expect(client.send(:disconnected_session_error?, err)).to be(true)
    end

    it "detects Playwright::Error when the message contains 'Target closed'" do
      err = Playwright::Error.new(message: "Target closed while waiting for selector")
      expect(client.send(:disconnected_session_error?, err)).to be(true)
    end

    it "detects Playwright::Error for the long 'Target page, context or browser has been closed' form" do
      err = Playwright::Error.new(message: "Target page, context or browser has been closed")
      expect(client.send(:disconnected_session_error?, err)).to be(true)
    end

    it "detects any StandardError whose message carries a Playwright-style 'connection closed' hint" do
      err = RuntimeError.new("Playwright connection closed")
      expect(client.send(:disconnected_session_error?, err)).to be(true)
    end

    it "still detects the Selenium 'not connected to devtools' signature" do
      err = StandardError.new("Chrome is Not Connected To DevTools")
      expect(client.send(:disconnected_session_error?, err)).to be(true)
    end

    it "returns false for unrelated errors" do
      err = StandardError.new("something else entirely")
      expect(client.send(:disconnected_session_error?, err)).to be(false)
    end
  end

  describe "#with_recoverable_session" do
    it "retries a disconnected error and eventually succeeds" do
      attempts = 0
      expect(Rails.logger).to receive(:warn).with(/recovered from browser disconnect/)

      client.send(:with_recoverable_session, label: "test", max_attempts: 3) do
        attempts += 1
        raise StandardError, "Target closed" if attempts == 1
        :ok
      end

      expect(attempts).to eq(2)
    end

    it "re-raises after max_attempts" do
      expect(Rails.logger).to receive(:warn).at_least(:once)

      expect {
        client.send(:with_recoverable_session, label: "test", max_attempts: 2) do
          raise StandardError, "Target closed"
        end
      }.to raise_error(/Target closed/)
    end

    it "re-raises non-disconnection errors immediately" do
      expect {
        client.send(:with_recoverable_session, label: "test") do
          raise ArgumentError, "unrelated"
        end
      }.to raise_error(ArgumentError, "unrelated")
    end
  end
end
