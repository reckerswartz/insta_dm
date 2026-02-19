require "rails_helper"

RSpec.describe "UI Profile Modal Responsiveness", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "keeps captured profile post view flow responsive when configured" do
    next unless ensure_ui_audit_server!

    profile_path = resolve_profile_path
    if profile_path.empty?
      strict = ENV.fetch("UI_AUDIT_REQUIRE_PROFILE_PATH", "0") == "1"
      expect(strict).to eq(false), "Unable to resolve profile path. Set UI_AUDIT_PROFILE_PATH=/instagram_profiles/:id"
      next
    end

    report = run_ui_audit(
      routes: [profile_path],
      max_actions: Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_PROFILE", "8")),
      include_table_actions: ENV.fetch("UI_AUDIT_INCLUDE_TABLE_ACTIONS", "0") == "1",
      include_nav_actions: ENV.fetch("UI_AUDIT_INCLUDE_NAV_ACTIONS", "0") == "1",
    )

    modal_actions = report[:pages].flat_map { |page| page[:actions] }.select do |action|
      action[:action].to_s.include?("open_profile_modal")
    end

    if modal_actions.empty?
      strict_modal = ENV.fetch("UI_AUDIT_REQUIRE_PROFILE_MODAL", "0") == "1"
      expect(strict_modal).to eq(false), "No profile modal trigger was discovered on #{profile_path}."
    else
      modal_action_seen = modal_actions.any? { |action| action[:status].to_s == "ok" }
      expect(modal_action_seen).to eq(true), "Expected at least one successful profile post modal interaction.\n#{format_ui_audit_issues(report)}"
    end

    expect(report.dig(:totals, :errors)).to eq(0), format_ui_audit_issues(report)
  end
end
