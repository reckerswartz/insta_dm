class LlmCommentGenerationChannel < ApplicationCable::Channel
  def subscribed
    requested_account_id = params[:account_id].to_i
    if requested_account_id <= 0
      reject
      return
    end

    stream_from "llm_comment_generation_#{requested_account_id}"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
