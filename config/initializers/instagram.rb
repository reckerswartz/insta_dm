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
