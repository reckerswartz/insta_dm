require "rails_helper"

RSpec.describe "UI Profile Modal Responsiveness", :diagnostic, :slow, :external_app, :diagnostic_ui do
  it "keeps captured profile post view flow responsive when configured" do
    next unless ensure_ui_audit_server!

    profile_path = ENV.fetch("UI_AUDIT_PROFILE_PATH", "").strip
    if profile_path.empty?
      expect(true).to eq(true)
      next
    end

    report = run_ui_audit(
      routes: [profile_path],
      max_actions: Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_PROFILE", "8")),
      include_table_actions: ENV.fetch("UI_AUDIT_INCLUDE_TABLE_ACTIONS", "0") == "1",
    )

    modal_action_seen = report[:pages].flat_map { |page| page[:actions] }.any? do |action|
      action[:action].to_s.include?("open_profile_modal") && action[:status].to_s == "ok"
    end

    expect(modal_action_seen).to eq(true), "Expected at least one successful profile post modal interaction.\n#{format_ui_audit_issues(report)}"
    expect(report.dig(:totals, :errors)).to eq(0), format_ui_audit_issues(report)
  end
end
