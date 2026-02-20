module Instagram
  class Client
    module FeedEngagementService
      # Captures "home feed" post identifiers that appear while scrolling.
      #
      # This does NOT auto-like or auto-comment. It only records posts, downloads media (temporarily),
      # and queues analysis. Interaction should remain a user-confirmed action in the UI.
      def capture_home_feed_posts!(rounds: 4, delay_seconds: 45, max_new: 20)
        with_recoverable_session(label: "feed_capture") do
          with_authenticated_driver do |driver|
            with_task_capture(driver: driver, task_name: "feed_capture_home", meta: { rounds: rounds, delay_seconds: delay_seconds, max_new: max_new }) do
              driver.navigate.to(INSTAGRAM_BASE_URL)
              wait_for(driver, css: "body", timeout: 12)
              dismiss_common_overlays!(driver)

              seen = 0
              new_posts = 0

              rounds.to_i.clamp(1, 25).times do |i|
                dismiss_common_overlays!(driver)

                items = extract_feed_items_from_dom(driver)
                now = Time.current

                items.each do |it|
                  sc = it[:shortcode].to_s.strip
                  next if sc.blank?

                  seen += 1

                  post = @account.instagram_posts.find_or_initialize_by(shortcode: sc)
                  is_new = post.new_record?

                  post.detected_at ||= now
                  post.post_kind = it[:post_kind].presence || post.post_kind.presence || "unknown"
                  post.author_username = it[:author_username].presence || post.author_username
                  post.media_url = it[:media_url].presence || post.media_url
                  post.caption = it[:caption].presence || post.caption
                  post.metadata = (post.metadata || {}).merge(it[:metadata] || {}).merge(round: i + 1)
                  post.save! if post.changed?

                  if is_new
                    new_posts += 1

                    # Download media and analyze (best effort).
                    DownloadInstagramPostMediaJob.perform_later(instagram_post_id: post.id) if post.media_url.present?
                    AnalyzeInstagramPostJob.perform_later(instagram_post_id: post.id)
                  end

                  break if new_posts >= max_new.to_i.clamp(1, 200)
                end

                break if new_posts >= max_new.to_i.clamp(1, 200)

                # Scroll down a bit.
                driver.execute_script("window.scrollBy(0, Math.max(700, window.innerHeight * 0.85));")
                sleep(delay_seconds.to_i.clamp(10, 120))
              end

              { seen_posts: seen, new_posts: new_posts }
            end
          end
        end
      end
      # Full Selenium automation flow:
      # - navigate home feed
      # - optionally engage one story first (hold/freeze until reply)
      # - find image posts, download media, store profile history, analyze, generate comment, post first suggestion
      # - capture HTML/JSON/screenshot artifacts at each step
      def auto_engage_home_feed!(max_posts: 3, include_story: true, story_hold_seconds: 18)
        max_posts_i = max_posts.to_i.clamp(1, 10)
        include_story_bool = ActiveModel::Type::Boolean.new.cast(include_story)
        hold_seconds_i = story_hold_seconds.to_i.clamp(8, 40)

        with_recoverable_session(label: "auto_engage_home_feed") do
          with_authenticated_driver do |driver|
            with_task_capture(
              driver: driver,
              task_name: "auto_engage_home_feed_start",
              meta: { max_posts: max_posts_i, include_story: include_story_bool, story_hold_seconds: hold_seconds_i }
            ) do
              driver.navigate.to(INSTAGRAM_BASE_URL)
              wait_for(driver, css: "body", timeout: 12)
              dismiss_common_overlays!(driver)
              capture_task_html(driver: driver, task_name: "auto_engage_home_loaded", status: "ok")

              story_result =
                if include_story_bool
                  auto_engage_first_story!(driver: driver, story_hold_seconds: hold_seconds_i)
                else
                  { attempted: false, replied: false }
                end

              driver.navigate.to(INSTAGRAM_BASE_URL)
              wait_for(driver, css: "body", timeout: 12)
              dismiss_common_overlays!(driver)
              sleep(0.6)
              capture_task_html(driver: driver, task_name: "auto_engage_home_before_posts", status: "ok")

              feed_items = extract_feed_items_from_dom(driver).select do |item|
                item[:post_kind] == "post" &&
                  item[:shortcode].to_s.present? &&
                  item[:media_url].to_s.start_with?("http://", "https://")
              end
              capture_task_html(
                driver: driver,
                task_name: "auto_engage_posts_discovered",
                status: "ok",
                meta: { discovered_posts: feed_items.length, max_posts: max_posts_i }
              )

              processed = 0
              commented = 0
              details = []

              feed_items.each do |item|
                break if processed >= max_posts_i
                processed += 1

                begin
                  result = auto_engage_feed_post!(driver: driver, item: item)
                  details << result
                  commented += 1 if result[:comment_posted] == true
                rescue StandardError => e
                  details << {
                    shortcode: item[:shortcode],
                    username: item[:author_username],
                    comment_posted: false,
                    error: e.message.to_s
                  }
                end
              end

              {
                story_replied: story_result[:replied] == true,
                posts_commented: commented,
                posts_processed: processed,
                details: details
              }
            end
          end
        end
      end

    end
  end
end
