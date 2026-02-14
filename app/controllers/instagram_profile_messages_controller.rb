class InstagramProfileMessagesController < ApplicationController
  before_action :require_current_account!

  def create
    profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
    body = params.dig(:instagram_message, :body).to_s.strip
    raise "Message cannot be blank" if body.blank?

    message = current_account.instagram_messages.create!(
      instagram_profile: profile,
      direction: "outgoing",
      body: body,
      status: "queued"
    )

    SendInstagramMessageJob.perform_later(instagram_account_id: current_account.id, instagram_message_id: message.id)

    respond_to do |format|
      format.html { redirect_to instagram_profile_path(profile), notice: "Message queued for delivery." }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.prepend("messages", partial: "instagram_messages/row", locals: { message: message }),
          turbo_stream.replace("message_form", partial: "instagram_messages/form", locals: { profile: profile, message: profile.instagram_messages.new })
        ]
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_profile_path(params[:instagram_profile_id]), alert: "Send failed: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Send failed: #{e.message}" }
        )
      end
    end
  end
end
