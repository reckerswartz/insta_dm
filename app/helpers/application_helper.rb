module ApplicationHelper
  def relative_time_with_tooltip(value, blank: "-")
    return blank if value.blank?

    time = value.in_time_zone
    relative =
      if time <= Time.current
        "#{time_ago_in_words(time)} ago"
      else
        "in #{time_ago_in_words(time)}"
      end

    content_tag(
      :time,
      relative,
      datetime: time.iso8601,
      title: time.strftime("%Y-%m-%d %H:%M:%S %Z")
    )
  end

  def top_nav_link_to(name = nil, path = nil, section:, **options, &block)
    if block_given?
      path = name
      name = capture(&block)
    end

    active = top_nav_active?(section)
    classes = [ "nav-link", options.delete(:class) ]
    classes << "active" if active

    aria_options = (options.delete(:aria) || {}).dup
    aria_options[:current] = "page" if active

    link_to name, path, **options.merge(class: classes.compact.join(" "), aria: aria_options)
  end

  def get_default_test_for_service(service)
    case service.to_s
    when 'vision'
      'labels'
    when 'face'
      'detection'
    when 'ocr'
      'text_extraction'
    when 'whisper'
      'transcription'
    when 'video'
      'analysis'
    else
      'basic'
    end
  end

  def ai_dashboard_path
    ai_dashboard_index_path
  end

  def current_section
    case controller_path
    when "instagram_accounts"
      :accounts
    when "instagram_profiles", "instagram_profile_actions", "instagram_profile_posts", "instagram_profile_messages"
      :profiles
    when "instagram_posts"
      :posts
    when "ai_dashboard"
      :ai_dashboard
    when "admin/background_jobs"
      if action_name == "dashboard" || request.path.start_with?("/admin/jobs")
        :jobs
      elsif %w[failures failure].include?(action_name)
        :failures
      end
    when "admin/issues"
      :issues
    when "admin/storage_ingestions"
      :storage
    else
      nil
    end
  end

  private

  def top_nav_active?(section)
    case section
    when :accounts
      controller_path == "instagram_accounts"
    when :profiles
      %w[
        instagram_profiles
        instagram_profile_actions
        instagram_profile_posts
        instagram_profile_messages
      ].include?(controller_path)
    when :posts
      controller_path == "instagram_posts"
    when :ai_dashboard
      controller_path == "ai_dashboard"
    when :jobs
      request.path.start_with?("/admin/jobs") || (controller_path == "admin/background_jobs" && action_name == "dashboard")
    when :failures
      controller_path == "admin/background_jobs" && %w[failures failure].include?(action_name)
    when :issues
      controller_path == "admin/issues"
    when :storage
      controller_path == "admin/storage_ingestions"
    else
      false
    end
  end
end
