class OperationsChannel < ApplicationCable::Channel
  def subscribed
    requested_account_id = params[:account_id].to_i
    connection_account_id = current_account_id.to_i
    account_id = requested_account_id.positive? ? requested_account_id : connection_account_id
    stream_from Ops::LiveUpdateBroadcaster.account_stream(account_id) if account_id.positive?

    include_global = truthy?(params[:include_global]) || account_id <= 0
    stream_from Ops::LiveUpdateBroadcaster.global_stream if include_global
  end

  private

  def truthy?(raw)
    value = raw.to_s.strip.downcase
    %w[1 true yes on].include?(value)
  end
end
