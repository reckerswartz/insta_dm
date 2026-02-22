class FeedCapturesController < ApplicationController
  before_action :require_current_account!

  def create
    rounds = params.fetch(:rounds, 4).to_i.clamp(1, 25)
    delay_seconds = params.fetch(:delay_seconds, 45).to_i.clamp(10, 120)
    max_new = params.fetch(:max_new, 20).to_i.clamp(1, 200)
    reservation = FeedCaptureThrottle.reserve!(account: current_account)

    unless reservation.reserved
      return render_already_queued(remaining_seconds: reservation.remaining_seconds)
    end

    job = CaptureHomeFeedJob.perform_later(
      instagram_account_id: current_account.id,
      rounds: rounds,
      delay_seconds: delay_seconds,
      max_new: max_new,
      slot_claimed: true,
      trigger_source: "manual_feed_capture"
    )

    FeedCaptureActivityLog.append!(
      account: current_account,
      status: "queued",
      source: "manual",
      message: "Queued feed capture job #{job.job_id} (rounds=#{rounds}, delay=#{delay_seconds}s, max_new=#{max_new})."
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
    FeedCaptureThrottle.release!(
      account: current_account,
      previous_enqueued_at: reservation&.previous_enqueued_at
    ) if reservation&.reserved

    FeedCaptureActivityLog.append!(
      account: current_account,
      status: "failed",
      source: "manual",
      message: "Failed to queue feed capture: #{e.class}: #{e.message}"
    )

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

  private

  def render_already_queued(remaining_seconds:)
    remaining_i = remaining_seconds.to_i
    message =
      if remaining_i.positive?
        "Feed capture is already queued or running. Try again in about #{helpers.distance_of_time_in_words(Time.current, Time.current + remaining_i.seconds)}."
      else
        "Feed capture is already queued or running."
      end

    FeedCaptureActivityLog.append!(
      account: current_account,
      status: "skipped",
      source: "manual",
      message: "Skipped duplicate manual trigger while another feed capture was already queued."
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_account_path(current_account), alert: message }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: message }
        )
      end
      format.json { render json: { error: message }, status: :too_many_requests }
    end
  end
end
