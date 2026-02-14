class FeedCapturesController < ApplicationController
  before_action :require_current_account!

  def create
    rounds = params.fetch(:rounds, 4).to_i.clamp(1, 25)
    delay_seconds = params.fetch(:delay_seconds, 45).to_i.clamp(10, 120)
    max_new = params.fetch(:max_new, 20).to_i.clamp(1, 200)

    CaptureHomeFeedJob.perform_later(
      instagram_account_id: current_account.id,
      rounds: rounds,
      delay_seconds: delay_seconds,
      max_new: max_new
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_account_path(current_account), notice: "Feed capture queued." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Feed capture queued." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_account_path(current_account), alert: "Unable to queue feed capture: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue feed capture: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end
end
