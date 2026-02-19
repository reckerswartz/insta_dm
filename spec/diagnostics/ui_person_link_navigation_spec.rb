require "rails_helper"
require "selenium-webdriver"

RSpec.describe "UI Person Link Navigation", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "opens person pages from captured posts without turbo frame-missing errors" do
    next unless ensure_ui_audit_server!

    profile_path = ENV.fetch("UI_AUDIT_PROFILE_PATH", "").strip
    profile_path = "/instagram_profiles/367" if profile_path.empty?
    post_id = ENV.fetch("UI_AUDIT_PERSON_LINK_POST_ID", "109").to_i
    target_path = URI.join(ui_audit_base_url, profile_path).to_s

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument("--headless=new")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1600,1000")

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      wait = Selenium::WebDriver::Wait.new(timeout: ui_audit_wait_seconds)
      driver.navigate.to(target_path)
      wait.until do
        state = driver.execute_script("return document.readyState")
        %w[interactive complete].include?(state)
      end
      wait.until { driver.find_elements(css: "#captured_profile_posts_section").any? }

      card_xpath = <<~XPATH.squish
        //article[contains(@class,"story-media-card")]
        [.//form[contains(@action,"/instagram_profile_posts/#{post_id}/analyze")]]
      XPATH
      links = driver.find_elements(xpath: "#{card_xpath}//a[contains(@class,'face-pill-link')]")
      if links.empty?
        strict = ENV.fetch("UI_AUDIT_REQUIRE_PERSON_LINK", "0") == "1"
        expect(strict).to eq(false), "No person link found for post id #{post_id} on #{profile_path}."
        next
      end

      driver.execute_script(<<~JS)
        window.__personLinkDiag = { frameMissing: [], rejections: [], errors: [] }
        document.addEventListener("turbo:frame-missing", (event) => {
          window.__personLinkDiag.frameMissing.push({
            frameId: event?.target?.id || "",
            responseUrl: event?.detail?.response?.url || ""
          })
        })
        window.addEventListener("unhandledrejection", (event) => {
          const reason = event?.reason?.message || event?.reason || ""
          window.__personLinkDiag.rejections.push(String(reason))
        })
        window.addEventListener("error", (event) => {
          window.__personLinkDiag.errors.push(String(event?.message || ""))
        })
      JS

      link = links.first
      driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'})", link)
      driver.execute_script("arguments[0].click()", link)
      wait.until { driver.current_url.include?("/people/") }

      diag = driver.execute_script("return window.__personLinkDiag || {}") || {}
      expect(Array(diag["frameMissing"])).to eq([]),
        "Detected turbo:frame-missing while opening person link: #{diag.inspect}"
      expect(Array(diag["rejections"]).grep(/expected <turbo-frame/i)).to eq([]),
        "Detected Turbo frame rejection while opening person link: #{diag.inspect}"
      expect(driver.current_url).to include("/people/")
      expect(driver.page_source).to include("Identity Controls")
    ensure
      driver&.quit
    end
  end
end
