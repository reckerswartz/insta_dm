#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["UI_AUDIT_REQUIRE_SERVER"] ||= "1"
ENV["UI_AUDIT_REQUIRE_STORY_ACCOUNT_PATH"] ||= "1"

args = [
  "bundle", "exec", "rspec",
  "spec/diagnostics/ui_story_archive_responsiveness_spec.rb",
  "--tag", "diagnostic_ui",
  *ARGV,
]

exec(*args)
