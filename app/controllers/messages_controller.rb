class MessagesController < ApplicationController
  before_action :require_current_account!

  def create
    message_text = params[:message_text].to_s.strip
    raise "Message cannot be blank" if message_text.blank?

    usernames = current_account.recipients.selected.eligible.pluck(:username)
    raise "No selected recipients are eligible for messaging" if usernames.empty?

    result = Instagram::Client.new(account: current_account).send_messages!(usernames: usernames, message_text: message_text)

    redirect_to root_path, notice: "Messages attempted: #{result[:attempted]}, sent: #{result[:sent]}, failed: #{result[:failed]}"
  rescue StandardError => e
    redirect_to root_path, alert: "Sending failed: #{e.message}"
  end
end
