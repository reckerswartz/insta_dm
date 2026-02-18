module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :connection_id

    def connect
      self.connection_id = SecureRandom.hex(8)
    end
  end
end
