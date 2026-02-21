class StoryReplyStatusChannel < ApplicationCable::Channel
  def subscribed
    requested_account_id = params[:account_id].to_i
    if requested_account_id <= 0
      reject
      return
    end

    stream_from "story_reply_status_#{requested_account_id}"
  end

  def unsubscribed
    # No-op
  end
end
