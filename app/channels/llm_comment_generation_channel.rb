class LlmCommentGenerationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "llm_comment_generation_#{params[:account_id]}"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
