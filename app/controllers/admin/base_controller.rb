class Admin::BaseController < ApplicationController
  before_action :require_admin!

  private

  def require_admin!
    user = Rails.application.credentials.dig(:admin, :user).presence || ENV["ADMIN_USER"].to_s
    pass = Rails.application.credentials.dig(:admin, :password).presence || ENV["ADMIN_PASSWORD"].to_s

    # If no creds are configured, leave admin pages open for easier setup.
    # You can enable auth later by setting both credentials/admin env vars.
    return if user.blank? && pass.blank?
    if user.blank? || pass.blank?
      render plain: "Admin credentials are partially configured. Set both user and password, or clear both to disable auth.", status: :service_unavailable
      return
    end

    authenticate_or_request_with_http_basic("Admin") do |u, p|
      ActiveSupport::SecurityUtils.secure_compare(u.to_s, user.to_s) &
        ActiveSupport::SecurityUtils.secure_compare(p.to_s, pass.to_s)
    end
  end
end
