class InstagramMessage < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile

  validates :body, presence: true

  scope :recent_first, -> { order(created_at: :desc) }

  def queued?
    status == "queued"
  end

  def sent?
    status == "sent"
  end

  def failed?
    status == "failed"
  end
end

