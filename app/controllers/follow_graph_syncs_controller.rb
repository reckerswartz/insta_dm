class FollowGraphSyncsController < ApplicationController
  before_action :require_current_account!

  def create
    run = current_account.sync_runs.create!(kind: "follow_graph", status: "queued")
    SyncFollowGraphJob.perform_later(instagram_account_id: current_account.id, sync_run_id: run.id)

    respond_to do |format|
      format.html { redirect_to instagram_profiles_path, notice: "Follow graph sync queued. You will be notified when it completes." }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: "Follow graph sync queued. You will be notified when it completes." }
          ),
          turbo_stream.replace(
            "sync_status",
            partial: "sync_runs/status",
            locals: { sync_run: run }
          )
        ]
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_profiles_path, alert: "Unable to queue follow graph sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue follow graph sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end
end
