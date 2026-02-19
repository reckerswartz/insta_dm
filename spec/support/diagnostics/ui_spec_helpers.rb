require "net/http"
require "securerandom"

module Diagnostics
  module UiSpecHelpers
    def ui_audit_base_url
      ENV.fetch("UI_AUDIT_BASE_URL", "http://127.0.0.1:3000")
    end

    def ui_audit_wait_seconds
      Integer(ENV.fetch("UI_AUDIT_WAIT_SECONDS", "10"))
    end

    def external_ui_server_up?
      response = Net::HTTP.get_response(URI.join(ui_audit_base_url, "/up"))
      response.code.to_i == 200
    rescue StandardError
      false
    end

    # Returns true when a UI target is reachable. When strict mode is enabled
    # (UI_AUDIT_REQUIRE_SERVER=1), this fails the example instead of no-oping.
    def ensure_ui_audit_server!
      return true if external_ui_server_up?

      strict = ENV.fetch("UI_AUDIT_REQUIRE_SERVER", "0") == "1"
      message = "UI audit server is not reachable at #{ui_audit_base_url}"
      expect(strict).to eq(false), message
      false
    end

    def fetch_ui_html(path)
      response = Net::HTTP.get_response(URI.join(ui_audit_base_url, path))
      return nil unless response.code.to_i.between?(200, 299)

      response.body.to_s
    rescue StandardError
      nil
    end

    def discover_account_show_path
      html = fetch_ui_html("/")
      return nil if html.to_s.empty?

      html[%r{/instagram_accounts/\d+}]
    end

    def discover_profile_show_path(account_path: nil)
      path = account_path.to_s.strip
      path = discover_account_show_path if path.empty?
      return nil if path.to_s.empty?

      html = fetch_ui_html(path)
      return nil if html.to_s.empty?

      html[%r{/instagram_profiles/\d+}]
    end

    def resolve_story_account_path
      configured = ENV.fetch("UI_AUDIT_STORY_ACCOUNT_PATH", "").strip
      return configured unless configured.empty?

      discover_account_show_path
    end

    def resolve_profile_path
      configured = ENV.fetch("UI_AUDIT_PROFILE_PATH", "").strip
      return configured unless configured.empty?

      discover_profile_show_path(account_path: ENV.fetch("UI_AUDIT_PROFILE_ACCOUNT_PATH", "").strip)
    end

    def run_ui_audit(routes:, max_actions:, include_table_actions: false, include_nav_actions: false)
      output_dir = Rails.root.join("tmp/diagnostic_specs/rspec_ui_audit/#{SecureRandom.hex(6)}").to_s
      Diagnostics::SeleniumUiAudit.new(
        base_url: ui_audit_base_url,
        routes: routes,
        max_actions: max_actions,
        wait_seconds: ui_audit_wait_seconds,
        include_table_actions: include_table_actions,
        include_nav_actions: include_nav_actions,
        output_dir: output_dir,
      ).run!
    end

    def format_ui_audit_issues(report)
      issues = Array(report[:issues])
      return "No issues found." if issues.empty?

      issues.first(30).map do |row|
        "[#{row[:severity]}] #{row[:type]} route=#{row[:page_url]} action=#{row[:action]} detail=#{row[:detail]}"
      end.join("\n")
    end
  end
end

RSpec.configure do |config|
  config.include Diagnostics::UiSpecHelpers, diagnostic_ui: true
end
