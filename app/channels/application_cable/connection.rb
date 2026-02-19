module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :connection_id, :current_account_id

    def connect
      self.connection_id = SecureRandom.hex(8)
      self.current_account_id = resolve_current_account_id
    rescue StandardError
      self.current_account_id = nil
    end

    private

    def resolve_current_account_id
      selected_id = request.session[:instagram_account_id].to_i
      if selected_id.positive? && InstagramAccount.exists?(id: selected_id)
        return selected_id
      end

      InstagramAccount.order(:id).limit(1).pick(:id)
    end
  end
end
