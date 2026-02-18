require "net/http"
require "digest"
require "set"

module Instagram
  class ProfileAnalysisCollector
    MAX_POST_IMAGE_BYTES = 6 * 1024 * 1024
    MAX_POST_VIDEO_BYTES = 80 * 1024 * 1024

    def initialize(account:, profile:)
      @account = account
      @profile = profile
      @client = Instagram::Client.new(account: account)
    end

    def collect_and_persist!(posts_limit: nil, comments_limit: 8, track_missing_as_deleted: false, sync_source: "instagram_profile_analysis_dataset")
      dataset = @client.fetch_profile_analysis_dataset!(
        username: @profile.username,
        posts_limit: posts_limit,
        comments_limit: comments_limit
      )

      synced_at = Time.current
      details = dataset[:profile] || {}
      update_profile_from_details!(details)

      fetched_shortcodes = Set.new
      summary = {
        created_count: 0,
        updated_count: 0,
        unchanged_count: 0,
        restored_count: 0,
        deleted_count: 0,
        created_shortcodes: [],
        updated_shortcodes: [],
        restored_shortcodes: [],
        deleted_shortcodes: [],
        analysis_candidate_shortcodes: [],
        feed_fetch: dataset[:feed_fetch].is_a?(Hash) ? dataset[:feed_fetch] : {}
      }

      persisted_posts = Array(dataset[:posts]).map do |post_data|
        result = persist_profile_post!(post_data, synced_at: synced_at, sync_source: sync_source)
        next nil unless result

        post = result[:post]
        fetched_shortcodes << post.shortcode.to_s

        case result[:change]
        when :created
          summary[:created_count] += 1
          summary[:created_shortcodes] << post.shortcode.to_s
        when :restored
          summary[:restored_count] += 1
          summary[:restored_shortcodes] << post.shortcode.to_s
        when :updated
          summary[:updated_count] += 1
          summary[:updated_shortcodes] << post.shortcode.to_s
        else
          summary[:unchanged_count] += 1
        end
        if result[:analysis_required]
          summary[:analysis_candidate_shortcodes] << post.shortcode.to_s
        end

        post
      end.compact

      if ActiveModel::Type::Boolean.new.cast(track_missing_as_deleted) && fetched_shortcodes.any?
        deleted = mark_missing_posts_as_deleted!(
          fetched_shortcodes: fetched_shortcodes,
          synced_at: synced_at,
          sync_source: sync_source
        )
        summary[:deleted_count] = deleted[:count]
        summary[:deleted_shortcodes] = deleted[:shortcodes]
      end

      {
        details: details,
        posts: persisted_posts,
        summary: summary.merge(
          created_shortcodes: Array(summary[:created_shortcodes]).uniq,
          updated_shortcodes: Array(summary[:updated_shortcodes]).uniq,
          restored_shortcodes: Array(summary[:restored_shortcodes]).uniq,
          deleted_shortcodes: Array(summary[:deleted_shortcodes]).uniq,
          analysis_candidate_shortcodes: Array(summary[:analysis_candidate_shortcodes]).uniq
        )
      }
    end

    private

    def update_profile_from_details!(details)
      attrs = {
        display_name: details[:display_name].presence || @profile.display_name,
        profile_pic_url: details[:profile_pic_url].presence || @profile.profile_pic_url,
        ig_user_id: details[:ig_user_id].presence || @profile.ig_user_id,
        bio: details[:bio].presence || @profile.bio,
        last_post_at: details[:last_post_at].presence || @profile.last_post_at
      }

      @profile.update!(attrs)
      @profile.recompute_last_active!
      @profile.save!
    end

    def persist_profile_post!(post_data, synced_at:, sync_source:)
      shortcode = post_data[:shortcode].to_s.strip
      return nil if shortcode.blank?

      post = @profile.instagram_profile_posts.find_or_initialize_by(shortcode: shortcode)
      previous_signature = post_signature(post)
      previous_analysis_signature = post_analysis_signature(post)
      was_new = post.new_record?
      was_deleted = post_deleted?(post)
      existing_metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      merged_metadata = existing_metadata.merge(
        "media_type" => post_data[:media_type],
        "media_id" => post_data[:media_id],
        "comments_count_api" => post_data[:comments_count],
        "source" => sync_source.to_s
      )
      merged_metadata.delete("deleted_from_source")
      merged_metadata.delete("deleted_detected_at")
      merged_metadata.delete("deleted_reason")
      merged_metadata["restored_at"] = synced_at.utc.iso8601(3) if was_deleted

      post.instagram_account = @account
      post.taken_at = post_data[:taken_at]
      post.caption = post_data[:caption]
      post.permalink = post_data[:permalink]
      post.source_media_url = post_data[:media_url].presence || post_data[:image_url]
      post.likes_count = post_data[:likes_count].to_i
      extracted_comments_count = Array(post_data[:comments]).size
      api_comments_count = post_data[:comments_count].to_i
      post.comments_count = [ extracted_comments_count, api_comments_count ].max
      post.last_synced_at = synced_at
      post.metadata = merged_metadata
      post.save!

      sync_media!(
        post: post,
        media_url: post_data[:media_url].presence || post_data[:image_url],
        media_id: post_data[:media_id]
      )
      sync_comments!(
        post: post,
        comments: post_data[:comments],
        expected_comments_count: post_data[:comments_count]
      )

      current_signature = post_signature(post.reload)
      current_analysis_signature = post_analysis_signature(post)
      changed = (previous_signature != current_signature)
      change =
        if was_new
          :created
        elsif was_deleted
          :restored
        elsif changed
          :updated
        else
          :unchanged
        end

      analysis_required =
        was_new ||
        was_deleted ||
        (previous_analysis_signature != current_analysis_signature) ||
        post.ai_status.to_s != "analyzed" ||
        post.analyzed_at.blank?
      if analysis_required && (post.ai_status.to_s != "pending" || post.analyzed_at.present?)
        post.update_columns(ai_status: "pending", analyzed_at: nil, updated_at: Time.current)
      end

      { post: post, change: change, analysis_required: analysis_required }
    end

    def sync_media!(post:, media_url:, media_id: nil)
      url = media_url.to_s.strip
      return false if url.blank?

      incoming_media_id = media_id.to_s.strip
      existing_metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      existing_media_id = existing_metadata["media_id"].to_s.strip
      if post.media.attached? && incoming_media_id.present? && existing_media_id.present? && incoming_media_id == existing_media_id
        return false
      end

      fp = Digest::SHA256.hexdigest(url)
      return false if post.media.attached? && post.media_url_fingerprint.to_s == fp

      io, content_type, filename = download_media(url)
      post.media.purge if post.media.attached?
      post.media.attach(io: io, filename: filename, content_type: content_type)
      post.update!(media_url_fingerprint: fp)
      true
    rescue StandardError => e
      Rails.logger.warn("[ProfileAnalysisCollector] media sync failed for shortcode=#{post.shortcode}: #{e.class}: #{e.message}")
      false
    ensure
      io&.close if defined?(io) && io.respond_to?(:close)
    end

    def sync_comments!(post:, comments:, expected_comments_count:)
      entries = Array(comments).first(20)
      normalized_entries = entries.filter_map do |c|
        body = c[:text].to_s.strip
        next if body.blank?
        [c[:author_username].to_s.strip.presence, body, c[:created_at]&.to_i]
      end
      existing_entries = post.instagram_profile_post_comments.order(:id).map do |comment|
        [comment.author_username.to_s.strip.presence, comment.body.to_s.strip, comment.commented_at&.to_i]
      end

      return if normalized_entries == existing_entries && normalized_entries.any?

      if entries.empty?
        # Keep previously captured comments when this sync could not fetch them.
        # Only clear if the source explicitly reports no comments.
        if expected_comments_count.to_i <= 0
          post.instagram_profile_post_comments.delete_all
        end
        return
      end

      post.instagram_profile_post_comments.delete_all

      entries.each do |c|
        body = c[:text].to_s.strip
        next if body.blank?

        post.instagram_profile_post_comments.create!(
          instagram_profile: @profile,
          author_username: c[:author_username].to_s.strip.presence,
          body: body,
          commented_at: c[:created_at],
          metadata: { source: "instagram_feed_preview" }
        )
      end
    end

    def download_media(url, redirects_left: 4)
      uri = URI.parse(url)
      raise "invalid media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"] = "*/*"
      req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
      req["Referer"] = Instagram::Client::INSTAGRAM_BASE_URL
      res = http.request(req)

      if res.is_a?(Net::HTTPRedirection) && res["location"].present?
        raise "too many redirects" if redirects_left.to_i <= 0

        redirected_url = normalize_redirect_url(base_uri: uri, location: res["location"])
        raise "invalid redirect URL" if redirected_url.blank?

        return download_media(redirected_url, redirects_left: redirects_left.to_i - 1)
      end

      raise "media download failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s
      content_type = res["content-type"].to_s.split(";").first.presence || "application/octet-stream"
      size_limit = content_type.start_with?("video/") ? MAX_POST_VIDEO_BYTES : MAX_POST_IMAGE_BYTES
      raise "media too large" if body.bytesize > size_limit

      ext = extension_for_content_type(content_type: content_type)
      io = StringIO.new(body)
      io.set_encoding(Encoding::BINARY) if io.respond_to?(:set_encoding)
      [io, content_type, "profile_post_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"]
    end

    def normalize_redirect_url(base_uri:, location:)
      target = URI.join(base_uri.to_s, location.to_s).to_s
      uri = URI.parse(target)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.to_s
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def extension_for_content_type(content_type:)
      return "jpg" if content_type.include?("jpeg")
      return "png" if content_type.include?("png")
      return "webp" if content_type.include?("webp")
      return "gif" if content_type.include?("gif")
      return "mp4" if content_type.include?("mp4")
      return "mov" if content_type.include?("quicktime")

      "bin"
    end

    def mark_missing_posts_as_deleted!(fetched_shortcodes:, synced_at:, sync_source:)
      missing = @profile.instagram_profile_posts.where.not(shortcode: fetched_shortcodes.to_a)
      shortcodes = []

      missing.find_each do |post|
        next if post_deleted?(post)

        metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        metadata["deleted_from_source"] = true
        metadata["deleted_detected_at"] = synced_at.utc.iso8601(3)
        metadata["deleted_reason"] = "missing_from_latest_capture"
        metadata["source"] = sync_source.to_s
        post.update!(metadata: metadata, last_synced_at: synced_at)
        shortcodes << post.shortcode.to_s
      end

      { count: shortcodes.length, shortcodes: shortcodes }
    end

    def post_deleted?(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      ActiveModel::Type::Boolean.new.cast(metadata["deleted_from_source"])
    end

    def post_signature(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      {
        shortcode: post.shortcode.to_s,
        taken_at: post.taken_at&.utc&.iso8601(3),
        caption: post.caption.to_s,
        permalink: post.permalink.to_s,
        source_media_url: post.source_media_url.to_s,
        likes_count: post.likes_count.to_i,
        comments_count: post.comments_count.to_i,
        media_url_fingerprint: post.media_url_fingerprint.to_s,
        media_id: metadata["media_id"].to_s,
        media_type: metadata["media_type"].to_s,
        deleted_from_source: ActiveModel::Type::Boolean.new.cast(metadata["deleted_from_source"])
      }
    end

    def post_analysis_signature(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      {
        shortcode: post.shortcode.to_s,
        taken_at: post.taken_at&.utc&.iso8601(3),
        caption: post.caption.to_s,
        source_media_url: post.source_media_url.to_s,
        media_url_fingerprint: post.media_url_fingerprint.to_s,
        media_id: metadata["media_id"].to_s,
        media_type: metadata["media_type"].to_s
      }
    end
  end
end
