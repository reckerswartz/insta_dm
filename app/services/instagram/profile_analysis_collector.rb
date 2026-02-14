require "net/http"
require "digest"

module Instagram
  class ProfileAnalysisCollector
    MAX_POST_IMAGE_BYTES = 6 * 1024 * 1024
    MAX_POST_VIDEO_BYTES = 80 * 1024 * 1024

    def initialize(account:, profile:)
      @account = account
      @profile = profile
      @client = Instagram::Client.new(account: account)
    end

    def collect_and_persist!(posts_limit: nil, comments_limit: 8)
      dataset = @client.fetch_profile_analysis_dataset!(
        username: @profile.username,
        posts_limit: posts_limit,
        comments_limit: comments_limit
      )

      details = dataset[:profile] || {}
      update_profile_from_details!(details)

      persisted_posts = Array(dataset[:posts]).map do |post_data|
        persist_profile_post!(post_data)
      end.compact

      {
        details: details,
        posts: persisted_posts
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

    def persist_profile_post!(post_data)
      shortcode = post_data[:shortcode].to_s.strip
      return nil if shortcode.blank?

      post = @profile.instagram_profile_posts.find_or_initialize_by(shortcode: shortcode)
      post.instagram_account = @account
      post.taken_at = post_data[:taken_at]
      post.caption = post_data[:caption]
      post.permalink = post_data[:permalink]
      post.source_media_url = post_data[:media_url].presence || post_data[:image_url]
      post.likes_count = post_data[:likes_count].to_i
      extracted_comments_count = Array(post_data[:comments]).size
      api_comments_count = post_data[:comments_count].to_i
      post.comments_count = [ extracted_comments_count, api_comments_count ].max
      post.last_synced_at = Time.current
      post.metadata = {
        media_type: post_data[:media_type],
        media_id: post_data[:media_id],
        comments_count_api: post_data[:comments_count],
        source: "instagram_profile_analysis_dataset"
      }
      post.save!

      sync_media!(post: post, media_url: post_data[:media_url].presence || post_data[:image_url])
      sync_comments!(
        post: post,
        comments: post_data[:comments],
        expected_comments_count: post_data[:comments_count]
      )

      post
    end

    def sync_media!(post:, media_url:)
      url = media_url.to_s.strip
      return if url.blank?

      fp = Digest::SHA256.hexdigest(url)
      return if post.media.attached? && post.media_url_fingerprint.to_s == fp

      io, content_type, filename = download_media(url)
      post.media.purge if post.media.attached?
      post.media.attach(io: io, filename: filename, content_type: content_type)
      post.update!(media_url_fingerprint: fp)
    rescue StandardError
      nil
    ensure
      io&.close if defined?(io) && io.respond_to?(:close)
    end

    def sync_comments!(post:, comments:, expected_comments_count:)
      entries = Array(comments).first(20)
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

    def download_media(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"] = "*/*"
      req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
      res = http.request(req)
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

    def extension_for_content_type(content_type:)
      return "jpg" if content_type.include?("jpeg")
      return "png" if content_type.include?("png")
      return "webp" if content_type.include?("webp")
      return "gif" if content_type.include?("gif")
      return "mp4" if content_type.include?("mp4")
      return "mov" if content_type.include?("quicktime")

      "bin"
    end
  end
end
