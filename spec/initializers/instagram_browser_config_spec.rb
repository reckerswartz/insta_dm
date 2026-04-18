require "rails_helper"

RSpec.describe Instagram::Browser::Config do
  describe ".driver" do
    it "defaults to selenium" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("INSTAGRAM_BROWSER_DRIVER").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:instagram, :browser_driver).and_return(nil)

      expect(described_class.driver).to eq("selenium")
      expect(described_class.selenium?).to be(true)
      expect(described_class.playwright?).to be(false)
    end

    it "honors the ENV override" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("INSTAGRAM_BROWSER_DRIVER").and_return("playwright")

      expect(described_class.driver).to eq("playwright")
      expect(described_class.playwright?).to be(true)
      expect(described_class.selenium?).to be(false)
    end

    it "falls back to the default when the value is invalid" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("INSTAGRAM_BROWSER_DRIVER").and_return("firefox")

      expect(described_class.driver).to eq("selenium")
    end
  end
end
