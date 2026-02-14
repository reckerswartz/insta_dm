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

  def top_nav_link_to(name, path, section:, **options)
    classes = [ "nav-link", options.delete(:class) ]
    classes << "active" if top_nav_active?(section)
    link_to name, path, **options.merge(class: classes.compact.join(" "))
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
    when :ai_providers
      controller_path == "admin/ai_providers"
    when :jobs
      request.path.start_with?("/admin/jobs") || (controller_path == "admin/background_jobs" && action_name == "dashboard")
    when :failures
      controller_path == "admin/background_jobs" && %w[failures failure].include?(action_name)
    else
      false
    end
  end
end
