require "rails_helper"
require "securerandom"
require "json"

# Phase 14 F-profiles-index-C1: the Phase 13 audit observed "Summary: 2
# Profiles | Tabulator grid: 0 rows" on /instagram_profiles and flagged it as
# a data-contract mismatch. Investigation showed the JSON endpoint does
# return the correct row count (2) — the "0" was the hard-coded loading
# placeholder that Tabulator overwrites on ajax completion. The real fix is
# to render the server-side `@total` in the meta-bar so the first paint
# already matches reality, and to keep the summary strip + the grid meta-bar
# in lock-step via the single `InstagramProfiles::ProfilesIndexQuery` service.
RSpec.describe "InstagramProfiles index summary ↔ grid meta-bar consistency", type: :request do
  let(:account) { InstagramAccount.create!(username: "phase14_profiles_#{SecureRandom.hex(4)}") }

  before do
    3.times do |i|
      account.instagram_profiles.create!(
        username: "profile_#{SecureRandom.hex(3)}_#{i}",
        display_name: "Profile #{i}"
      )
    end
    post select_instagram_account_path(account)
  end

  it "pre-populates the meta-bar with the server-computed @total (not the hard-coded 0 placeholder)" do
    get instagram_profiles_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Profiles: <strong>3</strong>")
    expect(response.body).to match(%r{<strong data-table-meta-count>\s*3\s*</strong>})
    expect(response.body).to include("from server")
  end

  it "renders the same total the JSON endpoint would return for an unfiltered request" do
    get instagram_profiles_path
    html_total_match = response.body.match(%r{<strong data-table-meta-count>\s*(\d+)\s*</strong>})
    rendered_total = html_total_match[1].to_i
    expect(html_total_match).to be_present, "meta-bar data-table-meta-count must render a number"

    get instagram_profiles_path(format: :json)
    json = JSON.parse(response.body)
    json_total = Array(json["data"]).size

    expect(rendered_total).to eq(json_total),
      "server-rendered meta-bar count (#{rendered_total}) must match JSON endpoint row count (#{json_total})"
    expect(rendered_total).to eq(3)
  end

  it "leaves the shared partial's default hard-coded 0 behaviour intact for callers that don't pass initial_count" do
    # Render the partial directly with no initial_count to confirm the
    # backwards-compatible fallback is preserved for other Tabulator pages
    # (failures, issues, storage, etc.) that have not been migrated yet.
    rendered = ApplicationController.render(
      partial: "shared/table_meta_bar",
      locals: { controls: nil, realtime_note: nil }
    )
    expect(rendered).to match(%r{<strong data-table-meta-count>\s*0\s*</strong>})
    expect(rendered).to include("loading...")
    expect(rendered).to include("Loading...")
  end
end
