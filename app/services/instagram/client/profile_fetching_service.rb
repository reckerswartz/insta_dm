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

        ui_result = verify_messageability_from_driver(driver, username: username)
        {
          can_message: ui_result[:can_message],
          restriction_reason: ui_result[:restriction_reason],
          source: ui_result[:source].to_s.presence || "ui",
          dm_state: ui_result[:dm_state],
          dm_reason: ui_result[:dm_reason],
          dm_retry_after_at: ui_result[:dm_retry_after_at]
        }
      end
    end

    def fetch_web_profile_info(username, driver: nil, force_refresh: false)
      uname = normalize_username(username)
      return nil if uname.blank?

      cache_key = "instagram:web_profile_info:account:#{@account.id}:#{uname}"
      unless force_refresh
        cached = Rails.cache.read(cache_key)
        return cached if cached.is_a?(Hash)
      end

      result = ig_api_get_json(
        path: "/api/v1/users/web_profile_info/?username=#{CGI.escape(uname)}",
        referer: "#{INSTAGRAM_BASE_URL}/#{uname}/",
        endpoint: "users/web_profile_info",
        username: uname,
        driver: driver,
        retries: 2
      )
      Rails.cache.write(cache_key, result, expires_in: 2.minutes) if result.is_a?(Hash)
      result
    rescue StandardError
      nil
    end

    def fetch_profile_details_from_driver(driver, username:)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      with_task_capture(driver: driver, task_name: "profile_fetch_details", meta: { username: username }) do
        api_details = fetch_profile_details_via_api(username, driver: driver)
        return api_details if api_details.present?

        driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
        wait_for(driver, css: "body", timeout: 10)
        dismiss_common_overlays!(driver)

        web_info = fetch_web_profile_info(username, driver: driver)
        web_user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        ig_user_id = web_user.is_a?(Hash) ? web_user["id"].to_s.strip.presence : nil
        bio = web_user.is_a?(Hash) ? web_user["biography"].to_s.presence : nil
        display_name = web_user.is_a?(Hash) ? web_user["full_name"].to_s.strip.presence : nil
        pic = web_user.is_a?(Hash) ? CGI.unescapeHTML(web_user["profile_pic_url_hd"].to_s).strip.presence || CGI.unescapeHTML(web_user["profile_pic_url"].to_s).strip.presence : nil
        followers_count = web_user.is_a?(Hash) ? normalize_count(web_user["follower_count"]) : nil
        category_name = web_user.is_a?(Hash) ? web_user["category_name"].to_s.strip.presence : nil
        is_business_account = web_user.is_a?(Hash) ? ActiveModel::Type::Boolean.new.cast(web_user["is_business_account"]) : nil

        post = extract_latest_post_from_profile_http(username, web_info: web_info, driver: driver)
        post = extract_latest_post_from_profile_dom(driver) if post[:taken_at].blank? && post[:shortcode].blank?

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

    def fetch_profile_details_via_api(username, driver: nil)
      uname = normalize_username(username)
      return nil if uname.blank?

      web_info = fetch_web_profile_info(uname, driver: driver)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      return nil unless user.is_a?(Hash)

      latest = extract_latest_post_from_profile_http(uname, web_info: web_info, driver: driver)
      latest = extract_latest_post_from_profile_dom(driver) if driver && latest[:taken_at].blank? && latest[:shortcode].blank?

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
