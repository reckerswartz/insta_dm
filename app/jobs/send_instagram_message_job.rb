class SendInstagramMessageJob < ApplicationJob
  queue_as :messages

  def perform(instagram_account_id:, instagram_message_id:)
    message = InstagramMessage.find(instagram_message_id)
    account = InstagramAccount.find(instagram_account_id)

    raise "Message/account mismatch" unless message.instagram_account_id == account.id

    message.update!(status: "queued", error_message: nil)
    broadcast_message(account: account, message: message)

    Instagram::Client.new(account: account).send_message_to_user!(
      username: message.instagram_profile.username,
      message_text: message.body
    )

    message.update!(status: "sent", sent_at: Time.current)
    broadcast_message(account: account, message: message)
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    message ||= InstagramMessage.where(id: instagram_message_id).first

    message&.update!(status: "failed", error_message: e.message)
    broadcast_message(account: account, message: message) if account && message
    raise
  end

  private

  def broadcast_message(account:, message:)
    Turbo::StreamsChannel.broadcast_replace_to(
      account,
      target: ActionView::RecordIdentifier.dom_id(message),
      partial: "instagram_messages/row",
      locals: { message: message }
    )
  end
end
