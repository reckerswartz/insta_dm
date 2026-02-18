class OperationsChannel < ApplicationCable::Channel
  def subscribed
    stream_from Ops::LiveUpdateBroadcaster.global_stream

    account_id = params[:account_id].to_i
    stream_from Ops::LiveUpdateBroadcaster.account_stream(account_id) if account_id.positive?
  end
end
