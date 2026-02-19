#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["UI_AUDIT_REQUIRE_SERVER"] ||= "1"
ENV["UI_AUDIT_REQUIRE_STORY_ACCOUNT_PATH"] ||= "1"
ENV["UI_AUDIT_REQUIRE_PROFILE_PATH"] ||= "1"

args = [
  "bundle", "exec", "rspec",
  "spec/diagnostics/ui_js_stability_core_spec.rb",
  "spec/diagnostics/ui_js_stability_admin_spec.rb",
  "spec/diagnostics/ui_story_archive_responsiveness_spec.rb",
  "spec/diagnostics/ui_profile_page_stability_spec.rb",
  "spec/diagnostics/ui_profile_modal_responsiveness_spec.rb",
  "--tag", "diagnostic_ui",
  *ARGV,
]

exec(*args)
