class ApplicationController < ActionController::Base
  private

  def current_account
    return @current_account if defined?(@current_account)

    # Prefer an explicitly selected account (multi-account support).
    selected_id = session[:instagram_account_id]
    @current_account =
      if selected_id.present?
        InstagramAccount.find_by(id: selected_id)
      end

    # Fallback to the first account if none selected.
    @current_account ||= InstagramAccount.order(:id).first

    # Optional bootstrap for older single-account setups.
    if @current_account.nil?
      bootstrap_username = Rails.application.config.x.instagram.username.to_s.strip
      @current_account = InstagramAccount.create!(username: bootstrap_username) if bootstrap_username.present?
    end

    @current_account
  end

  helper_method :current_account

  def require_current_account!
    return if current_account.present?

    redirect_to instagram_accounts_path, alert: "Add an Instagram account first."
  end
end
