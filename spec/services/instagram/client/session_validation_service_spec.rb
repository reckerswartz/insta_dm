require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client::SessionValidationService do
  let(:base_url) { "https://www.instagram.test" }
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:driver_class) do
    Struct.new(:current_url, :selector_map, keyword_init: true) do
      def navigate
        self
      end

      def to(url)
        self.current_url = url
      end

      def find_elements(css:)
        selector_map.fetch(css, [])
      end
    end
  end

  it "returns invalid when no cookies are stored" do
    with_driver = instance_double("WithDriver")
    wait_for = instance_double("WaitFor")
    allow(with_driver).to receive(:call)

    result = described_class.new(
      account: account,
      with_driver: with_driver,
      wait_for: wait_for,
      base_url: base_url
    ).call

    expect(result).to eq(valid: false, message: "No cookies stored")
    expect(with_driver).not_to have_received(:call)
  end

  it "returns invalid when homepage redirects to login" do
    account.cookies = [ { "name" => "sessionid", "value" => "cookie" } ]
    account.save!

    driver = driver_class.new(current_url: base_url, selector_map: {})
    with_driver = instance_double("WithDriver")
    wait_for = instance_double("WaitFor")

    allow(with_driver).to receive(:call).with(headless: true).and_yield(driver)
    allow(wait_for).to receive(:call) do |drv, css:, timeout:|
      drv.current_url = "#{base_url}/accounts/login/"
      expect(css).to eq("body")
      expect(timeout).to be_between(8, 12)
    end

    result = described_class.new(
      account: account,
      with_driver: with_driver,
      wait_for: wait_for,
      base_url: base_url
    ).call

    expect(result[:valid]).to eq(false)
    expect(result[:message]).to include("redirected to login page")
  end

  it "returns valid with sufficient authentication and profile indicators" do
    account.cookies = [ { "name" => "sessionid", "value" => "cookie" } ]
    account.save!

    visible = instance_double("Element", displayed?: true)
    selectors = {}
    described_class::AUTHENTICATED_SELECTORS.first(3).each { |selector| selectors[selector] = [ visible ] }
    described_class::PROFILE_INDICATORS.first(2).each { |selector| selectors[selector] = [ visible ] }

    driver = driver_class.new(current_url: base_url, selector_map: selectors)
    with_driver = instance_double("WithDriver")
    wait_for = instance_double("WaitFor")

    allow(with_driver).to receive(:call).with(headless: true).and_yield(driver)
    allow(wait_for).to receive(:call)

    result = described_class.new(
      account: account,
      with_driver: with_driver,
      wait_for: wait_for,
      base_url: base_url
    ).call

    expect(result[:valid]).to eq(true)
    expect(result[:details][:homepage_indicators]).to eq(3)
    expect(result[:details][:profile_indicators]).to eq(2)
  end
end
