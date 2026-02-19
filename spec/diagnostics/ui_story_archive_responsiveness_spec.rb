require "rails_helper"

RSpec.describe "UI Story Archive Responsiveness", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "keeps archived-story view interactions responsive" do
    next unless ensure_ui_audit_server!

    account_path = resolve_story_account_path
    if account_path.to_s.empty?
      strict = ENV.fetch("UI_AUDIT_REQUIRE_STORY_ACCOUNT_PATH", "0") == "1"
      expect(strict).to eq(false), "Unable to discover an account path. Set UI_AUDIT_STORY_ACCOUNT_PATH=/instagram_accounts/:id"
      next
    end

    report = run_ui_audit(
      routes: [account_path],
      max_actions: Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_STORY", "12")),
      include_table_actions: ENV.fetch("UI_AUDIT_INCLUDE_TABLE_ACTIONS", "0") == "1",
      include_nav_actions: ENV.fetch("UI_AUDIT_INCLUDE_NAV_ACTIONS", "0") == "1",
    )

    page_actions = report[:pages].flat_map { |page| page[:actions] }
    expect(page_actions.any? { |action| action[:status].to_s == "ok" }).to eq(true),
      "Expected at least one successful interaction on #{account_path}."
    expect(report.dig(:totals, :errors)).to eq(0), format_ui_audit_issues(report)
  end
end
