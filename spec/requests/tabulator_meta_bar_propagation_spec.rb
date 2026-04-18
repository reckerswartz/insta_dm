require "rails_helper"
require "securerandom"

# Phase 14b: propagate the server-rendered `initial_count` pattern (landed for
# the profiles index in Phase 14) to the remaining Tabulator pages so their
# meta-bar first paint also matches truth instead of flashing "0 rows" while
# the ajax fetch resolves.
RSpec.describe "Tabulator meta-bar server-rendered counts across admin + posts indexes", type: :request do
  let(:account) { InstagramAccount.create!(username: "phase14b_#{SecureRandom.hex(4)}") }

  before do
    post select_instagram_account_path(account)
  end

  shared_examples "pre-populated meta-bar" do |label|
    it "renders data-table-meta-count with a real integer (not the hard-coded 0 placeholder)" do
      get path
      expect(response).to have_http_status(:ok)
      match = response.body.match(%r{<strong data-table-meta-count>\s*(\d+)\s*</strong>})
      expect(match).to be_present, "#{label}: data-table-meta-count must be present"
      # Value depends on dev DB; we assert the view picked a number rather
      # than the bare "0" default. For empty fixtures the server renders "0"
      # but with `from server` / `Ready` labels signalling it IS the server
      # value, not the loading placeholder.
      expect(response.body).to include("from server"), "#{label}: initial_updated must be propagated"
      expect(response.body).to include("Ready"), "#{label}: initial_state must be propagated"
    end

    it "matches the count the JSON endpoint would return" do
      get path
      html_match = response.body.match(%r{<strong data-table-meta-count>\s*(\d+)\s*</strong>})
      html_total = html_match[1].to_i

      get path, params: { format: :json }
      json = JSON.parse(response.body)
      json_total = json["last_row"].presence || Array(json["data"]).size

      expect(html_total).to eq(json_total.to_i),
        "#{label}: server-rendered count (#{html_total}) must match JSON endpoint's last_row (#{json_total})"
    end
  end

  describe "GET /instagram_posts" do
    let(:path) { instagram_posts_path }
    before do
      2.times do |i|
        account.instagram_posts.create!(shortcode: "phase14b_#{SecureRandom.hex(3)}_#{i}", detected_at: Time.current)
      end
    end
    include_examples "pre-populated meta-bar", "posts index"
  end

  describe "GET /admin/background_jobs/failures" do
    let(:path) { admin_background_job_failures_path }
    before do
      BackgroundJobFailure.create!(
        job_class: "SomeJob",
        queue_name: "sync",
        failure_kind: "runtime",
        retryable: false,
        error_class: "RuntimeError",
        error_message: "phase14b smoke",
        active_job_id: SecureRandom.uuid,
        occurred_at: Time.current
      )
    end
    include_examples "pre-populated meta-bar", "failures index"
  end

  describe "GET /admin/issues" do
    let(:path) { admin_issues_path }
    before do
      AppIssue.create!(
        fingerprint: SecureRandom.hex(16),
        issue_type: "test",
        source: "phase14b_spec",
        severity: "info",
        status: "open",
        title: "phase14b smoke",
        occurrences: 1,
        first_seen_at: Time.current,
        last_seen_at: Time.current
      )
    end
    include_examples "pre-populated meta-bar", "issues index"
  end

  describe "GET /admin/storage_ingestions" do
    let(:path) { admin_storage_ingestions_path }
    include_examples "pre-populated meta-bar", "storage ingestions index"
  end
end
