module Instagram
  class Client
    module AutoEngagementSupport
      private

      def auto_engage_first_story!(driver:, story_hold_seconds:)
        result = { attempted: false, replied: false, replied_count: 0, username: nil, story_ref: nil, processed_stories: 0 }

        username = fetch_story_users_via_api.keys.first.to_s
        if username.blank?
          result[:reply_skipped] = true
          result[:reply_skip_reason] = "api_story_users_unavailable"
          return result
        end
        return result if username.blank?

        result[:attempted] = true
        result[:username] = username

        profile = find_story_network_profile(username: username)
        unless profile
          capture_task_html(
            driver: driver,
            task_name: "auto_engage_story_out_of_network_skipped",
            status: "ok",
            meta: { username: username, reason: "profile_not_in_network" }
          )
          result[:reply_skipped] = true
          result[:reply_skip_reason] = "profile_not_in_network"
          return result
        end

        story_items = fetch_story_items_via_api(username: username)
        if story_items.blank?
          result[:reply_skipped] = true
          result[:reply_skip_reason] = "no_story_items"
          return result
        end

        story_items.each do |story|
          story_id = story[:story_id].to_s
          next if story_id.blank?

          result[:processed_stories] += 1
          story_ref = "#{username}:#{story_id}"
          result[:story_ref] ||= story_ref

          if ActiveModel::Type::Boolean.new.cast(story[:api_should_skip])
            result[:reply_skipped] = true
            result[:reply_skip_reason] = story[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator"
            next
          end

          can_reply = story[:can_reply]
          if can_reply == false
            result[:reply_skipped] = true
            result[:reply_skip_reason] = "api_can_reply_false"
            next
          end

          media_url = story[:media_url].to_s
          next if media_url.blank?

          download = download_media_with_metadata(url: media_url, user_agent: @account.user_agent)
          downloaded_at = Time.current
          downloaded_event = profile.record_event!(
            kind: "story_media_downloaded_via_feed",
            external_id: "story_media_downloaded_via_feed:#{story_ref}:#{downloaded_at.utc.iso8601(6)}",
            occurred_at: downloaded_at,
            metadata: {
              source: "selenium_story_viewer",
              media_source: "api_story_item",
              media_type: story[:media_type],
              username: username,
              story_id: story_id,
              story_ref: story_ref,
              download_link: media_url,
              media_size_bytes: download[:bytes].bytesize,
              content_type: download[:content_type],
              final_url: download[:final_url]
            }
          )
          downloaded_event.media.attach(
            io: StringIO.new(download[:bytes]),
            filename: download[:filename],
            content_type: download[:content_type]
          )
          InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)

          payload = build_auto_engagement_post_payload(
            profile: profile,
            shortcode: story_ref,
            caption: story[:caption],
            permalink: story[:permalink].to_s.presence || "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/",
            include_story_history: true
          )
          analysis = analyze_for_auto_engagement!(
            analyzable: downloaded_event,
            payload: payload,
            bytes: download[:bytes],
            content_type: download[:content_type],
            source_url: media_url
          )
          suggestions = generate_comment_suggestions_from_analysis!(
            profile: profile,
            payload: payload,
            analysis: analysis
          )
          comment_text = suggestions.first.to_s.strip
          next if comment_text.blank?

          comment_result = comment_on_story_via_api!(story_id: story_id, story_username: username, comment_text: comment_text)
          if !comment_result[:posted]
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/")
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            freeze_story_progress!(driver)
            comment_result = comment_on_story_via_ui!(driver: driver, comment_text: comment_text)
          end
          posted = comment_result[:posted]
          sleep(story_hold_seconds.to_i) if posted

          if posted
            result[:replied] = true
            result[:replied_count] = result[:replied_count].to_i + 1
            profile.record_event!(
              kind: "story_comment_posted_via_feed",
              external_id: "story_comment_posted_via_feed:#{story_ref}:#{Time.current.utc.iso8601(6)}",
              occurred_at: Time.current,
              metadata: {
                source: "selenium_story_viewer",
                username: username,
                story_id: story_id,
                story_ref: story_ref,
                comment_text: comment_text,
                submission_method: comment_result[:method],
                analysis: analysis
              }
            )
            attach_reply_comment_to_downloaded_event!(downloaded_event: downloaded_event, comment_text: comment_text)
          end
        rescue StandardError
          next
        end

        result
      rescue StandardError => e
        capture_task_html(
          driver: driver,
          task_name: "auto_engage_story_failed",
          status: "error",
          meta: { error_class: e.class.name, error_message: e.message }
        )
        result
      end

      def auto_engage_feed_post!(driver:, item:)
        shortcode = item[:shortcode].to_s
        username = normalize_username(item[:author_username].to_s)
        profile = find_or_create_profile_for_auto_engagement!(username: username)

        capture_task_html(
          driver: driver,
          task_name: "auto_engage_post_selected",
          status: "ok",
          meta: { shortcode: shortcode, username: username, media_url: item[:media_url] }
        )

        download = download_media_with_metadata(url: item[:media_url], user_agent: @account.user_agent)
        downloaded_at = Time.current
        downloaded_event = profile.record_event!(
          kind: "feed_post_image_downloaded",
          external_id: "feed_post_image_downloaded:#{shortcode}:#{downloaded_at.utc.iso8601(6)}",
          occurred_at: downloaded_at,
          metadata: {
            source: "selenium_home_feed",
            shortcode: shortcode,
            download_link: item[:media_url],
            original_image_size_bytes: download[:bytes].bytesize,
            original_image_width: item.dig(:metadata, :natural_width),
            original_image_height: item.dig(:metadata, :natural_height),
            content_type: download[:content_type],
            final_url: download[:final_url]
          }
        )
        downloaded_event.media.attach(
          io: StringIO.new(download[:bytes]),
          filename: download[:filename],
          content_type: download[:content_type]
        )

        payload = build_auto_engagement_post_payload(
          profile: profile,
          shortcode: shortcode,
          caption: item[:caption],
          permalink: "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/",
          include_story_history: false
        )
        analysis = analyze_for_auto_engagement!(
          analyzable: downloaded_event,
          payload: payload,
          bytes: download[:bytes],
          content_type: download[:content_type],
          source_url: item[:media_url]
        )
        suggestions = generate_comment_suggestions_from_analysis!(
          profile: profile,
          payload: payload,
          analysis: analysis
        )

        comment_text = suggestions.first.to_s.strip
        posted = comment_text.present? && comment_on_post_via_ui!(driver: driver, shortcode: shortcode, comment_text: comment_text)

        profile.record_event!(
          kind: "feed_post_comment_posted",
          external_id: "feed_post_comment_posted:#{shortcode}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: {
            source: "selenium_home_feed",
            shortcode: shortcode,
            username: username,
            posted: posted,
            posted_comment: comment_text,
            generated_suggestions: suggestions.first(8),
            analysis: analysis
          }
        )

        {
          shortcode: shortcode,
          username: username,
          comment_posted: posted,
          posted_comment: comment_text
        }
      end

      def find_or_create_profile_for_auto_engagement!(username:)
        normalized = normalize_username(username)
        raise "Feed item username is missing" if normalized.blank?

        @account.instagram_profiles.find_or_create_by!(username: normalized) do |profile|
          profile.display_name = normalized
          profile.can_message = nil
        end
      end

      def find_story_network_profile(username:)
        normalized = normalize_username(username)
        return nil if normalized.blank?

        @account.instagram_profiles
          .where(username: normalized)
          .where("following = ? OR follows_you = ?", true, true)
          .first
      rescue StandardError
        nil
      end

      def find_profile_for_interaction(username:)
        normalized = normalize_username(username)
        return nil if normalized.blank?

        @account.instagram_profiles.where(username: normalized).first
      rescue StandardError
        nil
      end

      def profile_auto_reply_enabled?(profile)
        return profile.auto_reply_enabled? if profile.respond_to?(:auto_reply_enabled?)

        profile.profile_tags.where(name: [ "automatic_reply", "automatic reply", "auto_reply", "auto reply" ]).exists?
      end

      def build_auto_engagement_post_payload(profile:, shortcode:, caption:, permalink:, include_story_history: false)
        history = include_story_history ? recent_story_and_post_history(profile: profile) : {}
        history_narrative = profile.history_narrative_text(max_chunks: 3)
        history_chunks = profile.history_narrative_chunks(max_chunks: 6)

        {
          post: {
            shortcode: shortcode,
            caption: caption.to_s.presence,
            taken_at: nil,
            permalink: permalink,
            likes_count: nil,
            comments_count: nil,
            comments: []
          },
          author_profile: {
            username: profile.username,
            display_name: profile.display_name,
            bio: profile.bio,
            can_message: profile.can_message,
            tags: profile.profile_tags.pluck(:name).sort
          },
          rules: {
            require_manual_review: false,
            style: "gen_z_light",
            diversity_requirement: "Avoid repeating prior story comments; generate novel phrasing.",
            engagement_history: history,
            historical_narrative_text: history_narrative,
            historical_narrative_chunks: history_chunks
          }
        }
      end

      def analyze_for_auto_engagement!(analyzable:, payload:, bytes:, content_type:, source_url:)
        media = build_auto_engagement_media_payload(bytes: bytes, content_type: content_type, source_url: source_url)
        run = Ai::Runner.new(account: @account).analyze!(
          purpose: "post",
          analyzable: analyzable,
          payload: payload,
          media: media,
          media_fingerprint: Digest::SHA256.hexdigest(bytes)
        )

        run.dig(:result, :analysis).is_a?(Hash) ? run.dig(:result, :analysis) : {}
      rescue StandardError
        {}
      end

      def build_auto_engagement_media_payload(bytes:, content_type:, source_url:)
        payload = {
          type: "image",
          content_type: content_type,
          bytes: bytes,
          url: source_url.to_s
        }
        if bytes.bytesize <= 2 * 1024 * 1024
          payload[:image_data_url] = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
        end
        payload
      end

      def generate_comment_suggestions_from_analysis!(profile:, payload:, analysis:)
        suggestions = Array(analysis["comment_suggestions"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        suggestions = ensure_story_comment_diversity(profile: profile, suggestions: suggestions)
        return suggestions if suggestions.present?

        generated = generate_google_engagement_comments!(
          payload: payload,
          image_description: analysis["image_description"],
          topics: Array(analysis["topics"]),
          author_type: analysis["author_type"].to_s
        )
        ensure_story_comment_diversity(profile: profile, suggestions: generated)
      end

      def generate_google_engagement_comments!(payload:, image_description:, topics:, author_type:)
        generator = Ai::LocalEngagementCommentGenerator.new(
          ollama_client: Ai::OllamaClient.new
        )
        result = generator.generate!(
          post_payload: payload,
          image_description: image_description,
          topics: Array(topics),
          author_type: author_type.to_s,
          channel: "story"
        )
        suggestions = Array(result[:comment_suggestions]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        return suggestions if suggestions.present?

        fallback_story_comments(image_description: image_description, topics: topics)
      rescue StandardError
        fallback_story_comments(image_description: image_description, topics: topics)
      end

      def fallback_story_comments(image_description:, topics:)
        topic = Array(topics).map(&:to_s).find(&:present?).to_s
        visual_hint = image_description.to_s.split(/[.!?]/).first.to_s.strip
        visual_hint = visual_hint.gsub(/\s+/, " ").byteslice(0, 80)

        candidates = [
          "This one looks really good.",
          "Love the vibe in this story.",
          "Nice share.",
          (topic.present? ? "This #{topic} update is great." : nil),
          (visual_hint.present? ? "The #{visual_hint.downcase} looks awesome." : nil)
        ].compact

        candidates.map(&:strip).reject(&:blank?).uniq
      end

      def recent_story_and_post_history(profile:)
        story_items = profile.instagram_profile_events
          .where(kind: [ "story_analyzed", "story_reply_sent", "story_comment_posted_via_feed" ])
          .order(detected_at: :desc, id: :desc)
          .limit(12)
          .map do |event|
            m = event.metadata.is_a?(Hash) ? event.metadata : {}
            {
              kind: event.kind,
              story_id: m["story_id"].to_s.presence,
              image_description: m["ai_image_description"].to_s.presence,
              sent_comment: m["ai_reply_text"].to_s.presence || m["comment_text"].to_s.presence
            }.compact
          end

        post_items = profile.instagram_profile_posts.recent_first.limit(8).map do |p|
          a = p.analysis.is_a?(Hash) ? p.analysis : {}
          {
            shortcode: p.shortcode,
            image_description: a["image_description"].to_s.presence,
            topics: Array(a["topics"]).first(5)
          }.compact
        end

        {
          prior_story_items: story_items,
          prior_post_items: post_items
        }
      end

      def ensure_story_comment_diversity(profile:, suggestions:)
        candidates = Array(suggestions).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        return [] if candidates.empty?

        history = profile.instagram_profile_events
          .where(kind: [ "story_reply_sent", "story_comment_posted_via_feed" ])
          .order(detected_at: :desc, id: :desc)
          .limit(40)
          .map do |event|
            m = event.metadata.is_a?(Hash) ? event.metadata : {}
            m["ai_reply_text"].to_s.presence || m["comment_text"].to_s.presence
          end
          .compact

        return candidates if history.empty?

        ranked = candidates.sort_by do |candidate|
          history.map { |past| text_similarity_score(candidate, past) }.max.to_f
        end

        unique = ranked.select { |candidate| history.all? { |past| text_similarity_score(candidate, past) < 0.72 } }
        unique.present? ? unique : ranked
      end

      def story_already_replied?(profile:, story_id:, story_ref:, story_url:, media_url:)
        sid = story_id.to_s.strip
        sref = story_ref.to_s.strip
        surl = normalize_story_permalink(story_url)
        mkey = normalize_story_media_key(media_url)

        profile.instagram_profile_events
          .where(kind: "story_reply_sent")
          .order(detected_at: :desc, id: :desc)
          .limit(250)
          .each do |event|
            metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
            event_sid = metadata["story_id"].to_s.strip
            event_sref = metadata["story_ref"].to_s.strip
            event_surl = normalize_story_permalink(metadata["story_url"])
            event_mkey = normalize_story_media_key(metadata["media_url"])

            if sid.present? && (event_sid == sid || event.external_id.to_s == "story_reply_sent:#{sid}")
              return { found: true, matched_by: "story_id", matched_external_id: event.external_id.to_s }
            end
            if sref.present? && event_sref.present? && event_sref == sref
              return { found: true, matched_by: "story_ref", matched_external_id: event.external_id.to_s }
            end
            if surl.present? && event_surl.present? && event_surl == surl
              return { found: true, matched_by: "story_url", matched_external_id: event.external_id.to_s }
            end
            if mkey.present? && event_mkey.present? && event_mkey == mkey
              return { found: true, matched_by: "media_url", matched_external_id: event.external_id.to_s }
            end
          end

        { found: false, matched_by: nil, matched_external_id: nil }
      end

      def normalize_story_permalink(url)
        value = url.to_s.strip
        return "" if value.blank?

        begin
          uri = URI.parse(value)
          path = uri.path.to_s
        rescue StandardError
          path = value
        end

        return "" unless path.include?("/stories/")
        path.sub(%r{/\z}, "")
      end

      def normalize_story_media_key(url)
        value = url.to_s.strip
        return "" if value.blank?

        begin
          uri = URI.parse(value)
          host = uri.host.to_s
          path = uri.path.to_s
          return "" if host.blank? || path.blank?
          "#{host}#{path}"
        rescue StandardError
          value
        end
      end

      def text_similarity_score(a, b)
        left = a.to_s.downcase.scan(/[a-z0-9]+/).uniq
        right = b.to_s.downcase.scan(/[a-z0-9]+/).uniq
        return 0.0 if left.empty? || right.empty?

        (left & right).length.to_f / [ left.length, right.length ].max.to_f
      end

      def attach_reply_comment_to_downloaded_event!(downloaded_event:, comment_text:)
        return if downloaded_event.blank? || comment_text.blank?

        meta = downloaded_event.metadata.is_a?(Hash) ? downloaded_event.metadata.deep_dup : {}
        meta["reply_comment"] = comment_text.to_s
        downloaded_event.update!(metadata: meta)
      end
    end
  end
end
