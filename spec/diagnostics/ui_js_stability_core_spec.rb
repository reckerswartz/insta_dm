require "rails_helper"

RSpec.describe "UI JavaScript Stability (Core Routes)", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "captures no JavaScript errors on core routes" do
    next unless ensure_ui_audit_server!

    report = run_ui_audit(
      routes: %w[
        /
        /instagram_accounts
        /instagram_profiles
        /instagram_posts
      ],
      max_actions: Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_CORE", "6")),
      include_table_actions: ENV.fetch("UI_AUDIT_INCLUDE_TABLE_ACTIONS", "0") == "1",
    )

    expect(report.dig(:totals, :errors)).to eq(0), format_ui_audit_issues(report)
  end
end
