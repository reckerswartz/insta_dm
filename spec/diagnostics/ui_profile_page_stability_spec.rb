require "rails_helper"

RSpec.describe "UI Profile Page Stability", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "keeps profile page interactions responsive" do
    next unless ensure_ui_audit_server!

    profile_path = resolve_profile_path
    if profile_path.to_s.empty?
      strict = ENV.fetch("UI_AUDIT_REQUIRE_PROFILE_PATH", "0") == "1"
      expect(strict).to eq(false), "Unable to resolve profile path. Set UI_AUDIT_PROFILE_PATH=/instagram_profiles/:id"
      next
    end

    report = run_ui_audit(
      routes: [profile_path],
      max_actions: Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_PROFILE_PAGE", "16")),
      include_table_actions: ENV.fetch("UI_AUDIT_INCLUDE_TABLE_ACTIONS", "0") == "1",
      include_nav_actions: ENV.fetch("UI_AUDIT_INCLUDE_NAV_ACTIONS", "0") == "1",
    )

    page_actions = report[:pages].flat_map { |page| page[:actions] }
    expect(page_actions.any? { |action| action[:status].to_s == "ok" }).to eq(true),
      "Expected at least one successful interaction on #{profile_path}."
    expect(report.dig(:totals, :errors)).to eq(0), format_ui_audit_issues(report)
  end
end
