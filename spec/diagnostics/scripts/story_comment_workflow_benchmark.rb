#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["UI_AUDIT_REQUIRE_SERVER"] ||= "1"
ENV["UI_AUDIT_REQUIRE_STORY_ACCOUNT_PATH"] ||= "1"
ENV["UI_AUDIT_REQUIRE_STORY_CARD"] ||= "1"
ENV["UI_AUDIT_FORCE_REGENERATE"] ||= "1"

args = [
  "bundle", "exec", "rspec",
  "spec/diagnostics/ui_story_archive_comment_benchmark_spec.rb",
  "--tag", "diagnostic_ui",
  *ARGV
]

exec(*args)
