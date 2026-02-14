require "base64"
require "net/http"
require "digest"
require "stringio"

class SyncInstagramProfileStoriesJob < ApplicationJob
  queue_as :profiles

  MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024
  MAX_INLINE_VIDEO_BYTES = 10 * 1024 * 1024
  MAX_STORIES = 10

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil, max_stories: MAX_STORIES, force_analyze_all: false, auto_reply: false, require_auto_reply_tag: false)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    max_stories_i = max_stories.to_i.clamp(1, 10)
    force = ActiveModel::Type::Boolean.new.cast(force_analyze_all)
    auto_reply_enabled = ActiveModel::Type::Boolean.new.cast(auto_reply)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: auto_reply_enabled ? "auto_story_reply" : "sync_stories",
      profile_action_log_id: profile_action_log_id
    )
    tagged_for_auto_reply = automatic_reply_enabled?(profile)
    if require_auto_reply_tag && !tagged_for_auto_reply
      action_log.mark_succeeded!(log_text: "Skipped: automatic_reply tag not present", extra_metadata: { skipped: true, reason: "missing_automatic_reply_tag" })
      return
    end
    action_log.mark_running!(extra_metadata: {
      queue_name: queue_name,
      active_job_id: job_id,
      max_stories: max_stories_i,
      force_analyze_all: force,
      auto_reply: auto_reply_enabled
    })

    dataset = Instagram::Client.new(account: account).fetch_profile_story_dataset!(
      username: profile.username,
      stories_limit: max_stories_i
    )

    sync_profile_snapshot!(profile: profile, details: dataset[:profile] || {})

    stories = Array(dataset[:stories]).first(max_stories_i)
    downloaded_count = 0
    analyzed_count = 0
    reply_queued_count = 0

    stories.each do |story|
      story_id = story[:story_id].to_s
      next if story_id.blank?

      # Capture HTML snapshot for debugging story skipping
      capture_story_html_snapshot(profile: profile, story: story, story_index: stories.find_index(story))

      if story[:api_should_skip]
        profile.record_event!(
          kind: "story_skipped_debug",
          external_id: "story_skipped_debug:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            skip_reason: story[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator",
            skip_source: "api_story_item_attribution",
            skip_targets: Array(story[:api_external_profile_targets])
          )
        )
        next
      end

      already_processed = already_processed_story?(profile: profile, story_id: story_id)
      if already_processed && !force
        profile.record_event!(
          kind: "story_skipped_debug",
          external_id: "story_skipped_debug:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            skip_reason: "already_processed",
            force_analyze_all: force,
            story_index: stories.find_index(story),
            total_stories: stories.size
          )
        )
        next
      end

      upload_event = profile.record_event!(
        kind: "story_uploaded",
        external_id: "story_uploaded:#{story_id}",
        occurred_at: story[:taken_at],
        metadata: base_story_metadata(profile: profile, story: story)
      )

      viewed_at = Time.current
      profile.update!(last_story_seen_at: viewed_at)
      profile.recompute_last_active!
      profile.save!

      profile.record_event!(
        kind: "story_viewed",
        external_id: "story_viewed:#{story_id}:#{viewed_at.utc.iso8601(6)}",
        occurred_at: viewed_at,
        metadata: base_story_metadata(profile: profile, story: story).merge(viewed_at: viewed_at.iso8601)
      )

      media_url = story[:media_url].to_s.strip
      next if media_url.blank?

      bytes, content_type, filename = download_story_media(url: media_url, user_agent: account.user_agent)
      downloaded_at = Time.current
      downloaded_event = profile.record_event!(
        kind: "story_downloaded",
        external_id: "story_downloaded:#{story_id}:#{downloaded_at.utc.iso8601(6)}",
        occurred_at: downloaded_at,
        metadata: base_story_metadata(profile: profile, story: story).merge(
          downloaded_at: downloaded_at.iso8601,
          media_filename: filename,
          media_content_type: content_type,
          media_bytes: bytes.bytesize
        )
      )

      downloaded_event.media.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
      InstagramProfileEvent.broadcast_story_archive_refresh!(account: account)
      attach_media_to_event(upload_event, bytes: bytes, filename: filename, content_type: content_type)
      ingested_story = ingest_story_for_processing(
        account: account,
        profile: profile,
        story: story,
        downloaded_event: downloaded_event,
        bytes: bytes,
        content_type: content_type,
        filename: filename,
        force_reprocess: force
      )
      downloaded_count += 1

      analysis = analyze_story_for_comments(
        account: account,
        profile: profile,
        story: story,
        analyzable: downloaded_event,
        media_fingerprint: media_fingerprint_for_story(story: story, bytes: bytes, content_type: content_type),
        bytes: bytes,
        content_type: content_type
      )

      next unless analysis[:ok]

      analyzed_at = Time.current
      profile.record_event!(
        kind: "story_analyzed",
        external_id: "story_analyzed:#{story_id}:#{analyzed_at.utc.iso8601(6)}",
        occurred_at: analyzed_at,
        metadata: base_story_metadata(profile: profile, story: story).merge(
          analyzed_at: analyzed_at.iso8601,
          ai_provider: analysis[:provider],
          ai_model: analysis[:model],
          ai_image_description: analysis[:image_description],
          ai_comment_suggestions: analysis[:comment_suggestions],
          instagram_story_id: ingested_story&.id
        )
      )
      analyzed_count += 1

      if auto_reply_enabled
        decision = story_reply_decision(analysis: analysis, profile: profile, story_id: story_id)

        if decision[:queue]
          queued = queue_story_reply!(
            account: account,
            profile: profile,
            story: story,
            analysis: analysis
          )
          reply_queued_count += 1 if queued
        else
          profile.record_event!(
            kind: "story_reply_skipped",
            external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
            occurred_at: Time.current,
            metadata: base_story_metadata(profile: profile, story: story).merge(
              skip_reason: decision[:reason],
              relevant: analysis[:relevant],
              author_type: analysis[:author_type],
              suggestions_count: Array(analysis[:comment_suggestions]).length
            )
          )
        end
      end
    rescue StandardError
      next
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Story sync completed for #{profile.username}. Stories: #{stories.size}, downloaded: #{downloaded_count}, analyzed: #{analyzed_count}, replies queued: #{reply_queued_count}." }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        stories_found: stories.size,
        downloaded: downloaded_count,
        analyzed: analyzed_count,
        replies_queued: reply_queued_count
      },
      log_text: "Synced #{stories.size} stories (downloaded: #{downloaded_count}, analyzed: #{analyzed_count}, replies queued: #{reply_queued_count})"
    )
  rescue StandardError => e
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Story sync failed: #{e.message}" }
    ) if account
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, action:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: action,
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def sync_profile_snapshot!(profile:, details:)
    profile.update!(
      display_name: details[:display_name].presence || profile.display_name,
      profile_pic_url: details[:profile_pic_url].presence || profile.profile_pic_url,
      ig_user_id: details[:ig_user_id].presence || profile.ig_user_id,
      bio: details[:bio].presence || profile.bio,
      last_post_at: details[:last_post_at].presence || profile.last_post_at
    )
    profile.recompute_last_active!
    profile.save!
  end

  def base_story_metadata(profile:, story:)
    {
      source: "instagram_story_reel_api",
      story_id: story[:story_id],
      media_type: story[:media_type],
      media_url: story[:media_url],
      image_url: story[:image_url],
      video_url: story[:video_url],
      can_reply: story[:can_reply],
      can_reshare: story[:can_reshare],
      owner_user_id: story[:owner_user_id],
      owner_username: story[:owner_username],
      api_has_external_profile_indicator: story[:api_has_external_profile_indicator],
      api_external_profile_reason: story[:api_external_profile_reason],
      api_external_profile_targets: story[:api_external_profile_targets],
      api_should_skip: story[:api_should_skip],
      caption: story[:caption],
      permalink: story[:permalink],
      upload_time: story[:taken_at]&.iso8601,
      expiring_at: story[:expiring_at]&.iso8601,
      profile_context: {
        username: profile.username,
        display_name: profile.display_name,
        can_message: profile.can_message,
        tags: profile.profile_tags.pluck(:name).sort,
        bio: profile.bio.to_s.tr("\n", " ").byteslice(0, 260)
      }
    }
  end

  def automatic_reply_enabled?(profile)
    profile.profile_tags.where(name: [ "automatic_reply", "automatic reply" ]).exists?
  end

  def already_processed_story?(profile:, story_id:)
    profile.instagram_profile_events.where(kind: "story_uploaded", external_id: "story_uploaded:#{story_id}").exists?
  end

  def attach_media_to_event(event, bytes:, filename:, content_type:)
    return unless event
    return if event.media.attached?

    event.media.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
  rescue StandardError
    nil
  end

  def analyze_story_for_comments(account:, profile:, story:, analyzable:, media_fingerprint:, bytes:, content_type:)
    media_payload = build_media_payload(story: story, bytes: bytes, content_type: content_type)
    payload = build_story_payload(profile: profile, story: story)

    run = Ai::Runner.new(account: account).analyze!(
      purpose: "post",
      analyzable: analyzable,
      payload: payload,
      media: media_payload,
      media_fingerprint: media_fingerprint
    )

    analysis = run.dig(:result, :analysis)
    return { ok: false } unless analysis.is_a?(Hash)

    {
      ok: true,
      provider: run[:provider].key,
      model: run.dig(:result, :model),
      relevant: analysis["relevant"],
      author_type: analysis["author_type"],
      image_description: analysis["image_description"].to_s.presence,
      comment_suggestions: Array(analysis["comment_suggestions"]).first(8)
    }
  rescue StandardError
    { ok: false }
  end

  def media_fingerprint_for_story(story:, bytes:, content_type:)
    return Digest::SHA256.hexdigest(bytes) if bytes.present?

    fallback = [
      story[:media_url].to_s,
      story[:image_url].to_s,
      story[:video_url].to_s,
      content_type.to_s
    ].find(&:present?)
    return nil if fallback.blank?

    Digest::SHA256.hexdigest(fallback)
  end

  def build_story_payload(profile:, story:)
    story_history = recent_story_history_context(profile: profile)
    history_narrative = profile.history_narrative_text(max_chunks: 3)
    history_chunks = profile.history_narrative_chunks(max_chunks: 6)
    recent_post_context = profile.instagram_profile_posts.recent_first.limit(5).map do |p|
      {
        shortcode: p.shortcode,
        caption: p.caption.to_s,
        taken_at: p.taken_at&.iso8601,
        image_description: p.analysis.is_a?(Hash) ? p.analysis["image_description"] : nil,
        topics: p.analysis.is_a?(Hash) ? Array(p.analysis["topics"]).first(6) : []
      }
    end
    recent_event_context = profile.instagram_profile_events.order(detected_at: :desc).limit(20).pluck(:kind, :occurred_at).map do |kind, occurred_at|
      { kind: kind, occurred_at: occurred_at&.iso8601 }
    end

    {
      post: {
        shortcode: story[:story_id],
        caption: story[:caption],
        taken_at: story[:taken_at]&.iso8601,
        permalink: story[:permalink],
        likes_count: nil,
        comments_count: nil,
        comments: []
      },
      author_profile: {
        username: profile.username,
        display_name: profile.display_name,
        bio: profile.bio,
        can_message: profile.can_message,
        tags: profile.profile_tags.pluck(:name).sort,
        recent_posts: recent_post_context,
        recent_profile_events: recent_event_context,
        recent_story_history: story_history,
        historical_narrative_text: history_narrative,
        historical_narrative_chunks: history_chunks
      },
      rules: {
        require_manual_review: true,
        style: "gen_z_light",
        context: "story_reply_suggestion",
        only_if_relevant: true,
        diversity_requirement: "Prefer novel comments and avoid repeating previous story replies."
      }
    }
  end

  def story_reply_decision(analysis:, profile:, story_id:)
    return { queue: false, reason: "already_sent" } if story_reply_already_sent?(profile: profile, story_id: story_id)
    return { queue: false, reason: "official_messaging_not_configured" } unless official_messaging_service.configured?

    relevant = analysis[:relevant]
    author_type = analysis[:author_type].to_s
    suggestions = Array(analysis[:comment_suggestions]).map(&:to_s).reject(&:blank?)

    return { queue: false, reason: "no_comment_suggestions" } if suggestions.empty?
    return { queue: false, reason: "not_relevant" } unless relevant == true

    allowed_types = %w[personal_user friend relative unknown]
    return { queue: false, reason: "author_type_#{author_type.presence || 'missing'}_not_allowed" } unless allowed_types.include?(author_type)

    { queue: true, reason: "eligible_for_reply" }
  end

  def story_reply_already_sent?(profile:, story_id:)
    profile.instagram_profile_events.where(kind: "story_reply_sent", external_id: "story_reply_sent:#{story_id}").exists?
  end

  def queue_story_reply!(account:, profile:, story:, analysis:)
    story_id = story[:story_id].to_s
    suggestion = select_unique_story_comment(profile: profile, suggestions: Array(analysis[:comment_suggestions]))
    return false if suggestion.blank?

    result = official_messaging_service.send_text!(
      recipient_id: profile.ig_user_id.presence || profile.username,
      text: suggestion,
      context: {
        source: "story_auto_reply",
        story_id: story_id
      }
    )

    message = account.instagram_messages.create!(
      instagram_profile: profile,
      direction: "outgoing",
      body: suggestion,
      status: "sent",
      sent_at: Time.current
    )

    profile.record_event!(
      kind: "story_reply_sent",
      external_id: "story_reply_sent:#{story_id}",
      occurred_at: Time.current,
      metadata: base_story_metadata(profile: profile, story: story).merge(
        ai_reply_text: suggestion,
        auto_reply: true,
        instagram_message_id: message.id,
        provider_message_id: result[:provider_message_id]
      )
    )
    true
  rescue StandardError => e
    account.instagram_messages.create!(
      instagram_profile: profile,
      direction: "outgoing",
      body: suggestion.to_s,
      status: "failed",
      error_message: e.message.to_s
    ) if suggestion.present?
    false
  end

  def official_messaging_service
    @official_messaging_service ||= Messaging::IntegrationService.new
  end

  def recent_story_history_context(profile:)
    profile.instagram_profile_events
      .where(kind: [ "story_analyzed", "story_reply_sent", "story_comment_posted_via_feed" ])
      .order(detected_at: :desc, id: :desc)
      .limit(25)
      .map do |event|
        metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
        {
          kind: event.kind,
          occurred_at: event.occurred_at&.iso8601 || event.detected_at&.iso8601,
          story_id: metadata["story_id"].to_s.presence,
          image_description: metadata["ai_image_description"].to_s.presence,
          posted_comment: metadata["ai_reply_text"].to_s.presence || metadata["comment_text"].to_s.presence
        }.compact
      end
  end

  def select_unique_story_comment(profile:, suggestions:)
    candidates = Array(suggestions).map(&:to_s).map(&:strip).reject(&:blank?)
    return nil if candidates.empty?

    history = profile.instagram_profile_events
      .where(kind: [ "story_reply_sent", "story_comment_posted_via_feed" ])
      .order(detected_at: :desc, id: :desc)
      .limit(40)
      .map { |e| e.metadata.is_a?(Hash) ? (e.metadata["ai_reply_text"].to_s.presence || e.metadata["comment_text"].to_s) : "" }
      .reject(&:blank?)

    return candidates.first if history.empty?

    ranked = candidates.sort_by do |candidate|
      max_similarity = history.map { |past| text_similarity(candidate, past) }.max.to_f
      max_similarity
    end
    ranked.find { |c| history.all? { |past| text_similarity(c, past) < 0.72 } } || ranked.first
  end

  def text_similarity(a, b)
    left = tokenize(a)
    right = tokenize(b)
    return 0.0 if left.empty? || right.empty?

    overlap = (left & right).length.to_f
    overlap / [ left.length, right.length ].max.to_f
  end

  def tokenize(text)
    text.to_s.downcase.scan(/[a-z0-9]+/).uniq
  end

  def build_media_payload(story:, bytes:, content_type:)
    media_type = story[:media_type].to_s

    if media_type == "video"
      {
        type: "video",
        content_type: content_type,
        bytes: bytes.bytesize <= MAX_INLINE_VIDEO_BYTES ? bytes : nil
      }
    else
      payload = {
        type: "image",
        content_type: content_type,
        bytes: bytes
      }

      if bytes.bytesize <= MAX_INLINE_IMAGE_BYTES
        payload[:image_data_url] = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
      end

      payload
    end
  end

  def download_story_media(url:, user_agent:)
    uri = URI.parse(url)
    raise "Invalid story media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = user_agent.presence || "Mozilla/5.0"
    req["Accept"] = "*/*"
    req["Referer"] = "https://www.instagram.com/"

    res = http.request(req)

    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      return download_story_media(url: res["location"], user_agent: user_agent)
    end

    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    bytes = res.body.to_s
    raise "Empty story media body" if bytes.blank?

    content_type = res["content-type"].to_s.split(";").first.presence || "application/octet-stream"
    ext = extension_for_content_type(content_type: content_type)
    digest = Digest::SHA256.hexdigest("#{uri.path}-#{bytes.bytesize}")[0, 12]
    filename = "story_#{digest}.#{ext}"

    [ bytes, content_type, filename ]
  end

  def extension_for_content_type(content_type:)
    return "jpg" if content_type.include?("jpeg")
    return "png" if content_type.include?("png")
    return "webp" if content_type.include?("webp")
    return "mp4" if content_type.include?("mp4")
    return "mov" if content_type.include?("quicktime")

    "bin"
  end

  def ingest_story_for_processing(account:, profile:, story:, downloaded_event:, bytes:, content_type:, filename:, force_reprocess:)
    StoryIngestionService.new(account: account, profile: profile).ingest!(
      story: story,
      source_event: downloaded_event,
      bytes: bytes,
      content_type: content_type,
      filename: filename,
      force_reprocess: force_reprocess
    )
  rescue StandardError => e
    Rails.logger.warn("[SyncInstagramProfileStoriesJob] story ingestion failed story_id=#{story[:story_id]}: #{e.class}: #{e.message}")
    nil
  end

  def capture_story_html_snapshot(profile:, story:, story_index:)
    return unless story.present?

    begin
      # Create debug directory if it doesn't exist
      debug_dir = Rails.root.join("tmp", "story_debug_snapshots")
      FileUtils.mkdir_p(debug_dir) unless Dir.exist?(debug_dir)

      # Generate filename with timestamp and story info
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S_%L")
      filename = "#{profile.username}_story_#{story_index}_#{story[:story_id]}_#{timestamp}.html"
      filepath = File.join(debug_dir, filename)

      # Create HTML content with story metadata and DOM structure analysis
      html_content = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>Story Debug Snapshot - #{profile.username} - Story #{story_index}</title>
          <style>
            body { font-family: Arial, sans-serif; margin: 20px; }
            .header { background: #f0f0f0; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .metadata { background: #fff9e6; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .analysis { background: #e6f3ff; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .events { background: #ffe6e6; padding: 10px; border-radius: 5px; }
            pre { background: #f5f5f5; padding: 10px; border-radius: 3px; overflow-x: auto; }
            .story-id { color: #0066cc; font-weight: bold; }
            .skip-reason { color: #cc0000; font-weight: bold; }
          </style>
        </head>
        <body>
          <div class="header">
            <h1>Story Debug Snapshot</h1>
            <p><strong>Profile:</strong> #{profile.username} (ID: #{profile.id})</p>
            <p><strong>Story Index:</strong> #{story_index} / #{Array(story).size}</p>
            <p><strong>Captured At:</strong> #{Time.current.iso8601}</p>
          </div>

          <div class="metadata">
            <h2>Story Metadata</h2>
            <pre>#{JSON.pretty_generate(story)}</pre>
          </div>

          <div class="analysis">
            <h2>Processing Analysis</h2>
            <p><strong>Story ID:</strong> <span class="story-id">#{story[:story_id]}</span></p>
            <p><strong>Already Processed:</strong> #{already_processed_story?(profile: profile, story_id: story[:story_id].to_s)}</p>
            <p><strong>Media URL:</strong> #{story[:media_url]}</p>
            <p><strong>Taken At:</strong> #{story[:taken_at]}</p>
            <p><strong>Expiring At:</strong> #{story[:expiring_at]}</p>
          </div>

          <div class="events">
            <h2>Recent Story Events for this Profile</h2>
            <pre>#{JSON.pretty_generate(recent_story_events_for_debug(profile: profile))}</pre>
          </div>
        </body>
        </html>
      HTML

      # Write HTML snapshot to file
      File.write(filepath, html_content)

      # Log the snapshot creation
      Rails.logger.info "[STORY_DEBUG] HTML snapshot created: #{filepath}"

      # Record snapshot event in the database
      profile.record_event!(
        kind: "story_html_snapshot",
        external_id: "story_html_snapshot:#{story[:story_id]}:#{timestamp}",
        occurred_at: Time.current,
        metadata: base_story_metadata(profile: profile, story: story).merge(
          snapshot_filename: filename,
          snapshot_path: filepath,
          story_index: story_index,
          captured_at: Time.current.iso8601
        )
      )

    rescue StandardError => e
      Rails.logger.error "[STORY_DEBUG] Failed to capture HTML snapshot: #{e.message}"
      # Don't fail the entire job if snapshot capture fails
    end
  end

  def recent_story_events_for_debug(profile:)
    profile.instagram_profile_events
      .where(kind: [ "story_uploaded", "story_viewed", "story_analyzed", "story_skipped_debug" ])
      .order(occurred_at: :desc, id: :desc)
      .limit(20)
      .map do |event|
        {
          id: event.id,
          kind: event.kind,
          external_id: event.external_id,
          occurred_at: event.occurred_at&.iso8601,
          metadata: event.metadata.is_a?(Hash) ? event.metadata.slice("story_id", "skip_reason", "force_analyze_all", "story_index", "total_stories") : {}
        }
      end
  end
end
