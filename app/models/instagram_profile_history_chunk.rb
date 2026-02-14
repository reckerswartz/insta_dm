class InstagramProfileHistoryChunk < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile

  validates :sequence, presence: true
  validates :word_count, numericality: { greater_than_or_equal_to: 0 }
  validates :entry_count, numericality: { greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:sequence, :id) }
  scope :recent_first, -> { order(sequence: :desc, id: :desc) }
end
