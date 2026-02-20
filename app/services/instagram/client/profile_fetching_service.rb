module Instagram
  class Client
    module ProfileFetchingService
    def fetch_profile_details!(username:)
      with_recoverable_session(label: "fetch_profile_details") do
        with_authenticated_driver do |driver|
          fetch_profile_details_from_driver(driver, username: username)
        end
      end
    end

    def fetch_profile_details_and_verify_messageability!(username:)
      with_recoverable_session(label: "fetch_profile_details_and_verify_messageability") do
        with_authenticated_driver do |driver|
          details = fetch_profile_details_from_driver(driver, username: username)
          eligibility = verify_messageability_from_api(username: username)
          if eligibility[:can_message].nil?
            eligibility = verify_messageability_from_driver(driver, username: username)
          end
          details.merge(eligibility)
        end
      end
    end

    def fetch_eligibility(driver, username)
      with_task_capture(driver: driver, task_name: "sync_fetch_eligibility", meta: { username: username }) do
        api_result = verify_messageability_from_api(username: username)
        if api_result.is_a?(Hash) && !api_result[:can_message].nil?
          return {
            can_message: api_result[:can_message],
            restriction_reason: api_result[:restriction_reason],
            source: "api",
            dm_state: api_result[:dm_state],
            dm_reason: api_result[:dm_reason],
            dm_retry_after_at: api_result[:dm_retry_after_at]
          }
        end

        driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
        wait_for(driver, css: "body", timeout: 8)

        page = driver.page_source.to_s
        page_down = page.downcase

        # If we hit a generic error page or an interstitial, eligibility is unknown.
        if page_down.include?("something went wrong") ||
           page_down.include?("unexpected error") ||
           page_down.include?("polarishttp500") ||
           page_down.include?("try again later")
          return { can_message: false, restriction_reason: "Unable to verify messaging availability (profile load error)" }
        end

        # "Message" often renders as <div role="button"> on modern IG builds (not only <button>).
        message_cta =
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Message']").first ||
          driver.find_elements(xpath: "//*[self::a and @role='link' and normalize-space()='Message']").first

        follow_cta =
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Follow']").first ||
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Requested']").first

        if message_cta
          { can_message: true, restriction_reason: nil }
        elsif follow_cta
          { can_message: false, restriction_reason: "User is not currently messageable from this account" }
        elsif page_down.include?("private")
          { can_message: false, restriction_reason: "Private or restricted profile" }
        else
          { can_message: false, restriction_reason: "Unable to verify messaging availability" }
        end
      end
    end

    def fetch_web_profile_info(username)
      # Unofficial endpoint used by the Instagram web app; requires authenticated cookies.
      uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/users/web_profile_info/?username=#{username}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
      req["Accept"] = "application/json, text/plain, */*"
      req["X-Requested-With"] = "XMLHttpRequest"
      req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
      req["Referer"] = "#{INSTAGRAM_BASE_URL}/#{username}/"

      csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
      req["X-CSRFToken"] = csrf if csrf.present?
      req["Cookie"] = cookie_header_for(@account.cookies)

      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        remember_story_api_failure!(
          endpoint: "web_profile_info",
          url: uri.to_s,
          status: res.code.to_i,
          username: username,
          response_snippet: res.body
        ) if respond_to?(:remember_story_api_failure!, true)

        Ops::StructuredLogger.warn(
          event: "instagram.web_profile_info.http_failure",
          payload: {
            endpoint: "web_profile_info",
            username: username.to_s,
            status: res.code.to_i,
            rate_limited: res.code.to_i == 429,
            response_snippet: res.body.to_s.byteslice(0, 300)
          }
        )
        return nil
      end

      JSON.parse(res.body.to_s)
    rescue StandardError
      nil
    end

    def fetch_profile_details_from_driver(driver, username:)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      with_task_capture(driver: driver, task_name: "profile_fetch_details", meta: { username: username }) do
        api_details = fetch_profile_details_via_api(username)
        return api_details if api_details.present?

        driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
        wait_for(driver, css: "body", timeout: 10)
        dismiss_common_overlays!(driver)

        html = driver.page_source.to_s

        display_name = nil
        if (og = html.match(/property=\"og:title\" content=\"([^\"]+)\"/))
          og_title = CGI.unescapeHTML(og[1].to_s)
          # Examples: "Name (@username) • Instagram photos and videos"
          if (m = og_title.match(/\A(.+?)\s*\(@#{Regexp.escape(username)}\)\b/))
            display_name = m[1].to_s.strip
          end
        end

        pic = nil
        if (img = html.match(/property=\"og:image\" content=\"([^\"]+)\"/))
          pic = CGI.unescapeHTML(img[1].to_s).strip
        end

        web_info = fetch_web_profile_info(username)
        web_user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        ig_user_id = web_user.is_a?(Hash) ? web_user["id"].to_s.strip.presence : nil
        bio = web_user.is_a?(Hash) ? web_user["biography"].to_s.presence : nil
        full_name = web_user.is_a?(Hash) ? web_user["full_name"].to_s.strip.presence : nil
        followers_count = web_user.is_a?(Hash) ? normalize_count(web_user["follower_count"]) : nil
        followers_count ||= extract_profile_follow_counts(html)&.dig(:followers)
        category_name = web_user.is_a?(Hash) ? web_user["category_name"].to_s.strip.presence : nil
        is_business_account = web_user.is_a?(Hash) ? ActiveModel::Type::Boolean.new.cast(web_user["is_business_account"]) : nil

        display_name ||= full_name

        post = extract_latest_post_from_profile_dom(driver)
        post = extract_latest_post_from_profile_html(html) if post[:taken_at].blank? && post[:shortcode].blank?
        post = extract_latest_post_from_profile_http(username) if post[:taken_at].blank? && post[:shortcode].blank?

        {
          username: username,
          display_name: display_name,
          profile_pic_url: pic,
          ig_user_id: ig_user_id,
          bio: bio,
          followers_count: followers_count,
          category_name: category_name,
          is_business_account: is_business_account,
          last_post_at: post[:taken_at],
          latest_post_shortcode: post[:shortcode]
        }
      end
    end

    def fetch_profile_details_via_api(username)
      uname = normalize_username(username)
      return nil if uname.blank?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      return nil unless user.is_a?(Hash)

      latest = extract_latest_post_from_profile_http(uname)

      {
        username: uname,
        display_name: user["full_name"].to_s.strip.presence,
        profile_pic_url: CGI.unescapeHTML(user["profile_pic_url_hd"].to_s).strip.presence || CGI.unescapeHTML(user["profile_pic_url"].to_s).strip.presence,
        ig_user_id: user["id"].to_s.strip.presence,
        bio: user["biography"].to_s.presence,
        followers_count: normalize_count(user["follower_count"]),
        category_name: user["category_name"].to_s.strip.presence,
        is_business_account: ActiveModel::Type::Boolean.new.cast(user["is_business_account"]),
        last_post_at: latest[:taken_at],
        latest_post_shortcode: latest[:shortcode]
      }
    rescue StandardError
      nil
    end
    end
  end
end
