require "rails_helper"

RSpec.describe "Sidekiq schedule configuration" do
  it "resolves every scheduled job class" do
    schedule_path = Rails.root.join("config/sidekiq_schedule.yml")
    raw_schedule = YAML.safe_load(File.read(schedule_path), aliases: true) || {}

    class_names = raw_schedule
      .values
      .flat_map(&:to_h)
      .map { |(_, entry)| entry.to_h["class"] }
      .compact
      .uniq

    unresolved = class_names.reject { |name| name.safe_constantize.present? }
    expect(unresolved).to be_empty, "Unresolved Sidekiq schedule classes: #{unresolved.join(', ')}"
  end

  it "schedules account sync at most once every 24 hours" do
    schedule_path = Rails.root.join("config/sidekiq_schedule.yml")
    raw_schedule = YAML.safe_load(File.read(schedule_path), aliases: true) || {}

    %w[development production].each do |env_name|
      entry = raw_schedule.dig(env_name, "continuous_account_processing").to_h
      expect(entry["class"]).to eq("EnqueueContinuousAccountProcessingJob"), "#{env_name} missing continuous processing scheduler"
      expect(entry["cron"]).to eq("0 3 * * *"), "#{env_name} continuous processing must run once per day"
    end

    production_profile_refresh = raw_schedule.dig("production", "profile_refresh_all_accounts").to_h
    expect(production_profile_refresh["class"]).to eq("EnqueueProfileRefreshForAllAccountsJob")
    expect(production_profile_refresh["cron"]).to eq("30 3 * * *"), "production profile refresh must run once per day"
  end

  it "schedules story comment preparation every 5 minutes without auto reply sends" do
    schedule_path = Rails.root.join("config/sidekiq_schedule.yml")
    raw_schedule = YAML.safe_load(File.read(schedule_path), aliases: true) || {}

    %w[development production].each do |env_name|
      entry = raw_schedule.dig(env_name, "story_auto_reply_all_accounts").to_h
      args = Array(entry["args"]).first.to_h

      expect(entry["class"]).to eq("EnqueueStoryAutoRepliesForAllAccountsJob"), "#{env_name} missing story preparation scheduler"
      expect(entry["cron"]).to eq("*/5 * * * *"), "#{env_name} story preparation cron should be every 5 minutes"
      expect(args["max_stories"]).to eq(10)
      expect(args["profile_limit"]).to eq(1)
      expect(args["auto_reply"]).to eq(false)
      expect(args["require_auto_reply_tag"]).to eq(false)
    end
  end
end
