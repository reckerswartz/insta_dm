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
end
