#!/usr/bin/env ruby

require_relative "../config/environment"
require "json"
require "fileutils"

account_ids = ENV.fetch("ACCOUNT_IDS", "2")
  .split(",")
  .map(&:strip)
  .reject(&:empty?)
  .map(&:to_i)
sample_size = ENV.fetch("SAMPLE_SIZE", "15").to_i.clamp(5, 30)
output_root = Rails.root.join("tmp", "prompt_signal_samples")

def event_signal_snapshot(event)
  metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
  local = metadata["local_story_intelligence"].is_a?(Hash) ? metadata["local_story_intelligence"] : {}
  validated = metadata["validated_story_insights"].is_a?(Hash) ? metadata["validated_story_insights"] : {}
  verified = validated["verified_story_facts"].is_a?(Hash) ? validated["verified_story_facts"] : {}
  ownership = validated["ownership_classification"].is_a?(Hash) ? validated["ownership_classification"] : {}
  policy = validated["generation_policy"].is_a?(Hash) ? validated["generation_policy"] : {}

  {
    event_id: event.id,
    profile_id: event.instagram_profile_id,
    profile_username: event.instagram_profile&.username,
    occurred_at: event.occurred_at&.iso8601 || event.detected_at&.iso8601,
    content_type: event.media.blob.content_type.to_s,
    extracted: {
      ocr_text_present: verified["ocr_text"].to_s.present? || local["ocr_text"].to_s.present?,
      objects_count: Array(verified["objects"]).presence&.size || Array(local["objects"]).size,
      hashtags_count: Array(verified["hashtags"]).presence&.size || Array(local["hashtags"]).size,
      mentions_count: Array(verified["mentions"]).presence&.size || Array(local["mentions"]).size,
      profile_handles_count: Array(verified["profile_handles"]).presence&.size || Array(local["profile_handles"]).size,
      faces_count: (verified["face_count"] || local["face_count"]).to_i,
      identity_owner_likelihood: verified.dig("identity_verification", "owner_likelihood"),
      identity_confidence: verified.dig("identity_verification", "confidence"),
      ownership_label: ownership["label"],
      policy_allow_comment: policy["allow_comment"]
    }
  }
end

account_ids.each do |account_id|
  account = InstagramAccount.find_by(id: account_id)
  unless account
    puts "account=#{account_id} not found"
    next
  end

  events = InstagramProfileEvent
    .joins(:instagram_profile)
    .where(instagram_profiles: { instagram_account_id: account.id })
    .includes(:instagram_profile, media_attachment: :blob)
    .order(detected_at: :desc, id: :desc)
    .to_a
    .select { |event| event.media.attached? && event.media.blob.content_type.to_s.start_with?("image/") }
    .first(sample_size)

  folder = output_root.join("account_#{account.id}")
  FileUtils.mkdir_p(folder)

  snapshots = events.map do |event|
    ext = event.media.filename.extension_with_delimiter.presence || ".jpg"
    filename = "event_#{event.id}#{ext}"
    File.binwrite(folder.join(filename), event.media.download)
    event_signal_snapshot(event).merge(file: filename)
  end

  coverage = {
    sample_count: snapshots.size,
    ocr_present: snapshots.count { |row| row.dig(:extracted, :ocr_text_present) },
    objects_present: snapshots.count { |row| row.dig(:extracted, :objects_count).to_i > 0 },
    mentions_present: snapshots.count { |row| row.dig(:extracted, :mentions_count).to_i > 0 },
    handles_present: snapshots.count { |row| row.dig(:extracted, :profile_handles_count).to_i > 0 },
    faces_present: snapshots.count { |row| row.dig(:extracted, :faces_count).to_i > 0 },
    owner_likelihood_high: snapshots.count { |row| row.dig(:extracted, :identity_owner_likelihood).to_s == "high" },
    allow_comment_true: snapshots.count { |row| row.dig(:extracted, :policy_allow_comment) == true }
  }

  report = {
    generated_at: Time.current.iso8601,
    account_id: account.id,
    account_username: account.username,
    sample_size: snapshots.size,
    coverage: coverage,
    samples: snapshots
  }

  report_path = folder.join("audit_report.json")
  File.write(report_path, JSON.pretty_generate(report))
  puts "account=#{account.id} username=#{account.username} sample=#{snapshots.size} report=#{report_path}"
  puts "coverage=#{coverage.inspect}"
end
