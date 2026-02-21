class ApplicationController < ActionController::Base
  helper_method :queue_health_warning

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

  def queue_health_warning
    return @queue_health_warning if defined?(@queue_health_warning)

    @queue_health_warning = Rails.cache.fetch("ops/queue_health_warning", expires_in: 20.seconds) do
      status = Ops::QueueHealth.check!
      next nil if ActiveModel::Type::Boolean.new.cast(status[:ok])

      {
        reason: status[:reason].to_s,
        message: queue_health_warning_message(status),
        counts: status[:counts].is_a?(Hash) ? status[:counts] : {}
      }
    end
  rescue StandardError => e
    @queue_health_warning = {
      reason: "check_failed",
      message: "Queue health check failed: #{e.class} #{e.message}"
    }
  end

  def queue_health_warning_message(status)
    reason = status[:reason].to_s
    counts = status[:counts].is_a?(Hash) ? status[:counts] : {}

    return "Sidekiq workers are offline while jobs are queued. New background work is paused until workers recover." if reason == "no_workers_with_backlog"

    details = []
    details << "enqueued=#{counts[:enqueued].to_i}" if counts.key?(:enqueued)
    details << "scheduled=#{counts[:scheduled].to_i}" if counts.key?(:scheduled)
    details << "retries=#{counts[:retries].to_i}" if counts.key?(:retries)
    suffix = details.any? ? " (#{details.join(', ')})" : ""
    "Queue health is degraded#{suffix}."
  end
end
