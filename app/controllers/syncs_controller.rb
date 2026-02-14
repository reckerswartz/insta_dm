class SyncsController < ApplicationController
  before_action :require_current_account!

  def create
    result = Instagram::Client.new(account: current_account).sync_data!

    redirect_to root_path, notice: "Sync complete: #{result[:recipients]} recipients found, #{result[:eligible]} eligible for messaging."
  rescue StandardError => e
    redirect_to root_path, alert: "Sync failed: #{e.message}"
  end
end
