require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Diagnostics::SeleniumUiAudit do
  def build_audit(tmp_dir:, cache_path:, **options)
    described_class.new(
      base_url: "http://127.0.0.1:3000",
      routes: ["/instagram_accounts/1"],
      output_dir: tmp_dir,
      wait_seconds: 1,
      max_actions: 1,
      action_cache_path: cache_path,
      **options
    )
  end

  it "skips cached actions only after the minimum executed action threshold is met" do
    Dir.mktmpdir("ui_audit_spec") do |tmp_dir|
      cache_path = File.join(tmp_dir, "cache.json")
      payload = {
        "entries" => {
          "route|action_key" => {
            "last_seen_at" => Time.now.utc.iso8601,
            "status" => "ok"
          }
        }
      }
      File.write(cache_path, JSON.pretty_generate(payload))

      audit = build_audit(
        tmp_dir: tmp_dir,
        cache_path: cache_path,
        skip_cached_actions: true,
        min_actions_per_page: 1,
        action_cache_ttl_seconds: 600
      )

      cached_entry = audit.send(:reusable_cache_entry, cache_key: "route|action_key")
      expect(audit.send(:should_skip_cached_action?, cached_entry: cached_entry, executed_actions_count: 0)).to eq(false)
      expect(audit.send(:should_skip_cached_action?, cached_entry: cached_entry, executed_actions_count: 1)).to eq(true)
    end
  end

  it "treats stale cache entries as unusable when TTL has expired" do
    Dir.mktmpdir("ui_audit_spec") do |tmp_dir|
      cache_path = File.join(tmp_dir, "cache.json")
      payload = {
        "entries" => {
          "route|stale_action" => {
            "last_seen_at" => 3.hours.ago.utc.iso8601,
            "status" => "ok"
          }
        }
      }
      File.write(cache_path, JSON.pretty_generate(payload))

      audit = build_audit(
        tmp_dir: tmp_dir,
        cache_path: cache_path,
        skip_cached_actions: true,
        action_cache_ttl_seconds: 60
      )

      expect(audit.send(:reusable_cache_entry, cache_key: "route|stale_action")).to be_nil
    end
  end

  it "persists tracked actions with absolute screenshot paths in the cache file" do
    Dir.mktmpdir("ui_audit_spec") do |tmp_dir|
      cache_path = File.join(tmp_dir, "cache.json")
      audit = build_audit(
        tmp_dir: tmp_dir,
        cache_path: cache_path,
        skip_cached_actions: true
      )

      audit.send(
        :track_action_cache!,
        cache_key: "route|save_action",
        route: "http://127.0.0.1:3000/instagram_accounts/1",
        action: "generic_click: Save",
        status: "ok",
        screenshot: "actions/example.png"
      )
      audit.send(:persist_action_cache!)

      expect(File.exist?(cache_path)).to eq(true)

      stored = JSON.parse(File.read(cache_path))
      entry = stored.fetch("entries").fetch("route|save_action")
      expect(entry.fetch("status")).to eq("ok")
      expect(entry.fetch("screenshot")).to start_with(tmp_dir)
      expect(entry.fetch("screenshot")).to end_with("actions/example.png")
    end
  end
end
