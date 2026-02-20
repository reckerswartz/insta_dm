#!/usr/bin/env ruby
# frozen_string_literal: true

args = [
  "bundle", "exec", "rspec",
  "spec/diagnostics/prompt_signal_coverage_spec.rb",
  *ARGV,
]

exec(*args)
