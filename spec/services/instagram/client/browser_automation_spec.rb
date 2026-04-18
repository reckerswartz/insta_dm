require "rails_helper"

RSpec.describe Instagram::Client::BrowserAutomation do
  let(:account) { InstagramAccount.create!(username: "ba_#{SecureRandom.hex(4)}") }
  let(:client)  { Instagram::Client.new(account: account) }

  describe ".with_driver dispatch" do
    it "routes to the Selenium implementation in selenium mode" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(false)
      expect(client).to receive(:with_driver_selenium).with(headless: false).and_yield(:sel_driver)

      client.send(:with_driver, headless: false) { |d| expect(d).to eq(:sel_driver) }
    end

    it "routes to the Playwright implementation in playwright mode" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(true)
      expect(client).to receive(:with_driver_playwright).with(headless: true).and_yield(:pw_page)

      client.send(:with_driver, headless: true) { |d| expect(d).to eq(:pw_page) }
    end
  end

  describe ".with_authenticated_driver dispatch" do
    it "routes to selenium when config says selenium" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(false)
      expect(client).to receive(:with_authenticated_driver_selenium)
      client.send(:with_authenticated_driver) { }
    end

    it "routes to playwright when config says playwright" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(true)
      expect(client).to receive(:with_authenticated_driver_playwright)
      client.send(:with_authenticated_driver) { }
    end
  end

  describe "#manual_login! dispatch" do
    it "routes to manual_login_selenium! in selenium mode" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(false)
      expect(client).to receive(:manual_login_selenium!).with(timeout_seconds: 5)
      client.manual_login!(timeout_seconds: 5)
    end

    it "routes to manual_login_playwright! in playwright mode" do
      allow(Instagram::Browser::Config).to receive(:playwright?).and_return(true)
      expect(client).to receive(:manual_login_playwright!).with(timeout_seconds: 5)
      client.manual_login!(timeout_seconds: 5)
    end
  end

  describe "#with_authenticated_driver_playwright" do
    it "raises AuthenticationRequiredError when both the on-disk profile and the DB cookies are empty" do
      allow_any_instance_of(Instagram::Browser::AccountContext).to receive(:exists_on_disk?).and_return(false)
      allow(account).to receive(:cookies).and_return([])

      expect {
        client.send(:with_authenticated_driver_playwright) { :never }
      }.to raise_error(Instagram::AuthenticationRequiredError, /No stored cookies/)
    end

    it "opens a persistent context, ensures auth, yields the page, and refreshes the DB snapshot" do
      page = double("Playwright::Page")
      allow(page).to receive(:class).and_return(Class.new { def self.name; "Playwright::Page"; end })
      allow(page).to receive(:goto)
      allow(page).to receive(:url).and_return("https://www.instagram.com/")
      allow(page).to receive(:title).and_return("IG")
      allow(page).to receive(:evaluate).and_return("UA")
      allow(page).to receive(:screenshot)
      allow(page).to receive(:content).and_return("<html></html>")

      context = double("Playwright::BrowserContext", pages: [page], new_page: page,
                       storage_state: { "cookies" => [], "origins" => [] },
                       cookies: [])

      account_context = instance_double(Instagram::Browser::AccountContext,
                                        exists_on_disk?: true)
      allow(account_context).to receive(:with_context).and_yield(context)
      allow(Instagram::Browser::AccountContext).to receive(:new).with(account: account).and_return(account_context)

      allow(Instagram::Browser::PageInstrumentation).to receive(:attach!)
      # ensure_authenticated_playwright! calls wait_for + with_task_capture; stub them.
      allow(client).to receive(:wait_for).and_return(true)
      allow(client).to receive(:logged_out_page?).and_return(false)
      allow(client).to receive(:with_task_capture) { |*_args, **_kwargs, &blk| blk.call }
      allow(client).to receive(:refresh_account_snapshot_playwright!)

      yielded = nil
      client.send(:with_authenticated_driver_playwright) { |p| yielded = p }

      expect(yielded).to eq(page)
      expect(client).to have_received(:refresh_account_snapshot_playwright!).with(page, context)
    end
  end

  describe "#persist_session_bundle_playwright!" do
    it "delegates to SessionExporter#export! and updates user_agent + auth_snapshot" do
      exporter = instance_double(Instagram::Browser::SessionExporter)
      allow(Instagram::Browser::SessionExporter).to receive(:new).with(account: account).and_return(exporter)
      expect(exporter).to receive(:export!)

      page = double("Playwright::Page",
                    evaluate: "Mozilla/5.0 (Linux) Chrome/147",
                    url: "https://www.instagram.com/",
                    title: "IG")
      allow(page).to receive(:class).and_return(Class.new { def self.name; "Playwright::Page"; end })
      context = double("BrowserContext")

      # prime @account with some cookies so ig_app_id / sessionid_present logic runs
      account.update!(cookies: [{ "name" => "sessionid", "value" => "abc" }],
                      local_storage: [{ "origin" => "https://i.com", "name" => "k", "value" => "v" }])

      client.send(:persist_session_bundle_playwright!, page, context)
      # NOTE: intentionally do NOT account.reload; persist_session_bundle_playwright!
      # mirrors the Selenium version in leaving save! to the refresh_account_snapshot_*
      # caller. In-memory assignments are the contract.
      expect(account.user_agent).to start_with("Mozilla")
      expect(account.auth_snapshot["sessionid_present"]).to be(true)
      expect(account.auth_snapshot["cookie_names"]).to include("sessionid")
    end
  end
end
