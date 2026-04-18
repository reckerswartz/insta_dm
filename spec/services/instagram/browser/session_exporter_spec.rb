require "rails_helper"

RSpec.describe Instagram::Browser::SessionExporter do
  let(:account) do
    # Tests that DO hit the DB get a real InstagramAccount; the pure
    # translation tests use a stubbed struct to avoid migrations.
    InstagramAccount.create!(username: "test_exporter_#{SecureRandom.hex(4)}")
  end

  describe "#export!" do
    it "copies cookies, localStorage, and origin snapshot into the encrypted columns" do
      fake_context = double("Playwright::BrowserContext", storage_state: {
        "cookies" => [{
          "name" => "sessionid", "value" => "abc", "domain" => ".instagram.com",
          "path" => "/", "expires" => 1234567890.0,
          "httpOnly" => true, "secure" => true, "sameSite" => "Lax"
        }],
        "origins" => [{
          "origin" => "https://www.instagram.com",
          "localStorage" => [{ "name" => "_fbp", "value" => "xyz" }]
        }]
      })

      exporter = described_class.new(account: account)
      exporter.export!(fake_context)
      account.reload

      expect(account.cookies.length).to eq(1)
      expect(account.cookies.first["name"]).to eq("sessionid")

      ls = account.local_storage
      expect(ls.length).to eq(1)
      expect(ls.first).to include("origin" => "https://www.instagram.com",
                                  "name" => "_fbp", "value" => "xyz")

      snapshot = account.auth_snapshot
      expect(snapshot["exported_at"]).to be_present
      expect(snapshot["origins"]).to eq(["https://www.instagram.com"])
    end

    it "preserves the existing user_agent when the context does not expose one" do
      account.update!(user_agent: "Mozilla/5.0 existing")

      fake_context = double("Playwright::BrowserContext", storage_state: { "cookies" => [], "origins" => [] })
      described_class.new(account: account).export!(fake_context)
      account.reload

      expect(account.user_agent).to eq("Mozilla/5.0 existing")
    end
  end

  describe "#storage_state" do
    it "round-trips cookies and localStorage back into a Playwright-compatible hash" do
      account.update!(
        cookies: [{
          "name" => "sessionid", "value" => "abc", "domain" => ".instagram.com",
          "path" => "/", "expires" => 1234567890, "httpOnly" => true, "secure" => true, "sameSite" => "Lax"
        }],
        local_storage: [
          { "origin" => "https://www.instagram.com", "name" => "_fbp", "value" => "xyz" },
          { "origin" => "https://www.instagram.com", "name" => "ds_user_id", "value" => "1" }
        ]
      )

      state = described_class.new(account: account).storage_state

      expect(state[:cookies].first).to include(
        name: "sessionid",
        domain: ".instagram.com",
        path: "/",
        httpOnly: true,
        secure: true,
        sameSite: "Lax"
      )

      origin = state[:origins].first
      expect(origin[:origin]).to eq("https://www.instagram.com")
      expect(origin[:localStorage].map { |e| e[:name] }).to contain_exactly("_fbp", "ds_user_id")
    end

    it "defaults missing sameSite and expires to safe values" do
      account.update!(cookies: [{ "name" => "a", "value" => "1", "domain" => "x.com" }])

      state = described_class.new(account: account).storage_state
      c = state[:cookies].first
      expect(c[:sameSite]).to eq("Lax")
      expect(c[:expires]).to eq(-1)
      expect(c[:httpOnly]).to eq(false)
      expect(c[:secure]).to eq(false)
    end

    it "drops cookies that are missing name or value" do
      account.update!(cookies: [
        { "name" => "ok", "value" => "v", "domain" => "x.com" },
        { "value" => "v", "domain" => "x.com" },
        { "name" => "no_value", "domain" => "x.com" }
      ])

      state = described_class.new(account: account).storage_state
      expect(state[:cookies].map { |c| c[:name] }).to eq(["ok"])
    end
  end

  describe "#import!" do
    it "writes storage_state JSON next to the user data dir" do
      account.update!(cookies: [{ "name" => "a", "value" => "b", "domain" => "x.com" }])

      tmp = Pathname.new(Dir.mktmpdir).join("nested", "state.json")
      described_class.new(account: account).import!(path: tmp.to_s)

      hash = JSON.parse(File.read(tmp))
      expect(hash["cookies"].first["name"]).to eq("a")
    ensure
      FileUtils.rm_rf(tmp.dirname.dirname) if tmp
    end
  end
end
