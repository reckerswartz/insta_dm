boolean = ActiveModel::Type::Boolean.new
credentials = Rails.application.credentials

Rails.application.config.x.instagram = ActiveSupport::OrderedOptions.new
Rails.application.config.x.instagram.username =
  credentials.dig(:instagram, :username).presence || "change_me"

# Allow an env override for local debugging while keeping credentials as the default source of truth.
headless_setting =
  if ENV.key?("INSTAGRAM_HEADLESS")
    ENV.fetch("INSTAGRAM_HEADLESS")
  else
    credentials.dig(:instagram, :headless)
  end
Rails.application.config.x.instagram.headless =
  headless_setting.nil? ? true : boolean.cast(headless_setting)

max_followers_setting =
  if ENV.key?("INSTAGRAM_PROFILE_SCAN_MAX_FOLLOWERS")
    ENV.fetch("INSTAGRAM_PROFILE_SCAN_MAX_FOLLOWERS")
  else
    credentials.dig(:instagram, :profile_scan_max_followers)
  end
max_followers_i = max_followers_setting.to_s.strip.match?(/\A\d+\z/) ? max_followers_setting.to_i : 20_000
Rails.application.config.x.instagram.profile_scan_max_followers = max_followers_i.positive? ? max_followers_i : 20_000
