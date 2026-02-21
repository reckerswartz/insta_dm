#!/usr/bin/env ruby

require "json"
require "net/http"
require "uri"
require "erb"
require "fileutils"

class StoryAssignmentAuditor
  def initialize(days:, limit:, compare_live: false)
    @days = days.to_i.clamp(1, 30)
    @limit = limit.to_i.clamp(1, 500)
    @compare_live = ActiveModel::Type::Boolean.new.cast(compare_live)
    @timestamp = Time.current.utc.strftime("%Y%m%dT%H%M%SZ")
    @output_dir = Rails.root.join("tmp", "story_assignment_audit", @timestamp)
    @asset_dir = @output_dir.join("assets")
    FileUtils.mkdir_p(@asset_dir)
  end

  def run!
    events = InstagramProfileEvent
      .includes(instagram_profile: :instagram_account)
      .where(kind: "story_downloaded")
      .where("detected_at >= ?", @days.days.ago)
      .order(detected_at: :desc)
      .limit(@limit)

    rows = events.map { |event| inspect_event(event) }
    flagged = rows.select { |row| row[:issues].any? }
    report = {
      generated_at: Time.current.utc.iso8601(3),
      days: @days,
      scanned: rows.length,
      flagged: flagged.length,
      issue_counts: flagged.flat_map { |row| row[:issues] }.each_with_object(Hash.new(0)) { |issue, memo| memo[issue] += 1 },
      rows: flagged
    }

    json_path = @output_dir.join("report.json")
    html_path = @output_dir.join("report.html")
    File.write(json_path, JSON.pretty_generate(report))
    File.write(html_path, render_html(rows: flagged))

    {
      report: report,
      output_dir: @output_dir.to_s,
      json_path: json_path.to_s,
      html_path: html_path.to_s
    }
  end

  private

  def inspect_event(event)
    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    profile = event.instagram_profile
    profile_username = profile&.username.to_s
    story_id = metadata["story_id"].to_s
    story_url = metadata["story_url"].to_s
    owner_username = metadata["owner_username"].to_s
    validation = metadata["assignment_validation"].is_a?(Hash) ? metadata["assignment_validation"] : {}

    story_url_username, story_url_story_id = parse_story_identity(story_url)
    issues = []
    issues << "non_numeric_story_id" if story_id.present? && story_id !~ /\A\d+\z/
    if story_url_username.present? && profile_username.present? && normalize(profile_username) != normalize(story_url_username)
      issues << "story_url_username_mismatch"
    end
    if story_url_story_id.present? && story_id.present? && story_url_story_id != story_id
      issues << "story_url_story_id_mismatch"
    end
    if owner_username.present? && profile_username.present? && normalize(owner_username) != normalize(profile_username)
      issues << "owner_username_mismatch"
    end
    issues << "missing_assignment_validation" if validation.empty?
    if validation["status"].to_s == "failed"
      issues << "assignment_validation_failed"
    end

    assigned_media_path = export_assigned_media(event: event)
    live_media_path = @compare_live ? export_live_profile_media(event: event, story_id: story_id) : nil

    {
      event_id: event.id,
      detected_at: event.detected_at&.utc&.iso8601(3),
      profile_username: profile_username,
      story_id: story_id,
      story_url: story_url,
      story_url_username: story_url_username,
      story_url_story_id: story_url_story_id,
      owner_username: owner_username.presence,
      source: metadata["source"].to_s,
      media_source: metadata["media_source"].to_s,
      media_url: metadata["media_url"].to_s,
      issues: issues.uniq,
      assignment_validation: validation,
      assigned_media_path: assigned_media_path,
      live_media_path: live_media_path
    }
  rescue StandardError => e
    {
      event_id: event.id,
      issues: [ "audit_exception" ],
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def export_assigned_media(event:)
    return nil unless event.media.attached?

    blob = event.media.blob
    ext = extension_for_content_type(blob.content_type.to_s)
    filename = "event_#{event.id}_assigned.#{ext}"
    path = @asset_dir.join(filename)
    File.binwrite(path, blob.download)
    relative(path)
  rescue StandardError
    nil
  end

  def export_live_profile_media(event:, story_id:)
    sid = story_id.to_s
    return nil unless sid.match?(/\A\d+\z/)

    profile = event.instagram_profile
    account = profile&.instagram_account
    return nil unless profile && account

    client = Instagram::Client.new(account: account)
    dataset = client.fetch_profile_story_dataset!(username: profile.username, stories_limit: 20)
    story = Array(dataset[:stories]).find { |item| item.is_a?(Hash) && item[:story_id].to_s == sid }
    return nil unless story.is_a?(Hash)

    media_url = story[:media_url].to_s
    return nil if media_url.blank?

    payload = download_bytes(url: media_url, user_agent: account.user_agent)
    return nil unless payload

    ext = extension_for_content_type(payload[:content_type].to_s)
    filename = "event_#{event.id}_live.#{ext}"
    path = @asset_dir.join(filename)
    File.binwrite(path, payload[:bytes])
    relative(path)
  rescue StandardError
    nil
  end

  def download_bytes(url:, user_agent:)
    uri = URI.parse(url.to_s)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 8
    http.read_timeout = 20
    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = user_agent.to_s.presence || "Mozilla/5.0"
    request["Accept"] = "*/*"
    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    {
      bytes: response.body.to_s.b,
      content_type: response["content-type"].to_s.split(";").first.to_s
    }
  rescue StandardError
    nil
  end

  def parse_story_identity(story_url)
    value = story_url.to_s
    return [ "", "" ] unless value.include?("/stories/")

    rest = value.split("/stories/").last.to_s
    username = rest.split(/[\/?#]/).first.to_s
    story_id = rest.split("/")[1].to_s.split(/[?#]/).first.to_s
    [ username, story_id ]
  rescue StandardError
    [ "", "" ]
  end

  def extension_for_content_type(content_type)
    value = content_type.to_s.downcase
    return "jpg" if value.include?("jpeg")
    return "png" if value.include?("png")
    return "webp" if value.include?("webp")
    return "mp4" if value.include?("mp4")
    "bin"
  end

  def normalize(username)
    username.to_s.strip.downcase
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  rescue StandardError
    path.to_s
  end

  def render_html(rows:)
    items = rows.map do |row|
      issues = Array(row[:issues]).map { |item| "<li>#{ERB::Util.html_escape(item)}</li>" }.join
      assigned_tag = media_tag_for(path: row[:assigned_media_path], label: "Assigned")
      live_tag = media_tag_for(path: row[:live_media_path], label: "Live")
      <<~HTML
        <article class="card">
          <h3>Event ##{row[:event_id]} (#{ERB::Util.html_escape(row[:profile_username].to_s)})</h3>
          <p><strong>Detected:</strong> #{ERB::Util.html_escape(row[:detected_at].to_s)}</p>
          <p><strong>Story ID:</strong> #{ERB::Util.html_escape(row[:story_id].to_s)}</p>
          <p><strong>Story URL:</strong> <a href="#{ERB::Util.html_escape(row[:story_url].to_s)}" target="_blank" rel="noopener">open</a></p>
          <ul>#{issues}</ul>
          <div class="media-grid">
            #{assigned_tag}
            #{live_tag}
          </div>
        </article>
      HTML
    end.join("\n")

    <<~HTML
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8" />
          <title>Story Assignment Audit</title>
          <style>
            body { font-family: Arial, sans-serif; margin: 20px; background: #f8f9fb; }
            .card { background: #fff; border: 1px solid #dfe3eb; border-radius: 8px; padding: 12px; margin: 12px 0; }
            .media-grid { display: grid; grid-template-columns: repeat(2, minmax(220px, 1fr)); gap: 12px; }
            img, video { width: 100%; max-height: 420px; object-fit: contain; background: #111; border-radius: 6px; }
            .label { font-size: 12px; color: #444; margin: 4px 0; }
          </style>
        </head>
        <body>
          <h1>Story Assignment Audit</h1>
          <p>Rows: #{rows.length}</p>
          #{items}
        </body>
      </html>
    HTML
  end

  def media_tag_for(path:, label:)
    return "" if path.to_s.blank?

    escaped_path = ERB::Util.html_escape(path.to_s)
    if path.to_s.match?(/\.(mp4|mov)\z/i)
      <<~HTML
        <section>
          <p class="label">#{ERB::Util.html_escape(label)}</p>
          <video controls preload="metadata" src="../../#{escaped_path}"></video>
        </section>
      HTML
    else
      <<~HTML
        <section>
          <p class="label">#{ERB::Util.html_escape(label)}</p>
          <img src="../../#{escaped_path}" alt="#{ERB::Util.html_escape(label)}" />
        </section>
      HTML
    end
  end
end
