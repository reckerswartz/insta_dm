require "rails_helper"

RSpec.describe Instagram::Browser::AccountContext do
  let(:tmp_root) { Pathname.new(Dir.mktmpdir("account_ctx_spec_")) }
  let(:account) { build_stubbed(:instagram_account, id: 42, user_agent: "UA/test") rescue Struct.new(:id, :user_agent).new(42, "UA/test") }

  before do
    ENV["PLAYWRIGHT_BROWSER_SESSIONS_ROOT"] = tmp_root.to_s
    ENV["INSTAGRAM_HEADLESS"] = "true"
    # Reset class-level mutex registry so tests don't contaminate each other.
    described_class.instance_variable_set(:@account_mutexes, {})
  end

  after do
    ENV.delete("PLAYWRIGHT_BROWSER_SESSIONS_ROOT")
    ENV.delete("INSTAGRAM_HEADLESS")
    FileUtils.rm_rf(tmp_root)
  end

  describe "#user_data_dir" do
    it "lives under sessions_root/<account_id>" do
      expect(described_class.new(account: account).user_data_dir.to_s).to eq(tmp_root.join("42").to_s)
    end
  end

  describe "#with_context" do
    it "creates the user data dir, launches a persistent context, and closes it" do
      fake_context = instance_double("Playwright::BrowserContext", close: nil)
      fake_chromium = instance_double("Playwright::BrowserType",
                                       launch_persistent_context: fake_context)
      fake_driver = instance_double("Playwright::Playwright", chromium: fake_chromium)
      allow(Instagram::Browser::PlaywrightRuntime).to receive(:with_driver).and_yield(fake_driver)

      expect(fake_chromium).to receive(:launch_persistent_context).with(
        tmp_root.join("42").to_s,
        hash_including(
          headless: true,
          userAgent: "UA/test",
          viewport: { width: 1400, height: 1200 }
        )
      ).and_return(fake_context)
      expect(fake_context).to receive(:close)

      ctx = described_class.new(account: account)
      expect { |b| ctx.with_context(&b) }.to yield_with_args(fake_context)

      expect(File.directory?(tmp_root.join("42"))).to be(true)
    end

    it "closes the context even when the block raises, and does not swallow the error" do
      fake_context = instance_double("Playwright::BrowserContext")
      fake_chromium = instance_double("Playwright::BrowserType", launch_persistent_context: fake_context)
      fake_driver = instance_double("Playwright::Playwright", chromium: fake_chromium)
      allow(Instagram::Browser::PlaywrightRuntime).to receive(:with_driver).and_yield(fake_driver)
      expect(fake_context).to receive(:close)

      ctx = described_class.new(account: account)
      expect {
        ctx.with_context { raise "boom" }
      }.to raise_error("boom")
    end

    it "falls back to the default user agent when the account has none" do
      fake_context = instance_double("Playwright::BrowserContext", close: nil)
      fake_chromium = instance_double("Playwright::BrowserType", launch_persistent_context: fake_context)
      fake_driver = instance_double("Playwright::Playwright", chromium: fake_chromium)
      allow(Instagram::Browser::PlaywrightRuntime).to receive(:with_driver).and_yield(fake_driver)

      no_ua_account = Struct.new(:id, :user_agent).new(42, nil)
      expect(fake_chromium).to receive(:launch_persistent_context)
        .with(anything, hash_including(userAgent: described_class::DEFAULT_USER_AGENT))
        .and_return(fake_context)

      described_class.new(account: no_ua_account).with_context { }
    end
  end

  describe "#wipe!" do
    it "removes the on-disk user data dir" do
      ctx = described_class.new(account: account)
      FileUtils.mkdir_p(ctx.user_data_dir)
      File.write(ctx.user_data_dir.join("junk"), "data")

      ctx.wipe!

      expect(ctx.user_data_dir.exist?).to be(false)
    end
  end
end
