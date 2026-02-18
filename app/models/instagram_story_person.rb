class InstagramStoryPerson < ApplicationRecord
  ROLES = %w[primary_user secondary_person unknown].freeze

  belongs_to :instagram_account
  belongs_to :instagram_profile

  has_many :instagram_story_faces, dependent: :nullify
  has_many :instagram_post_faces, dependent: :nullify

  validates :role, presence: true, inclusion: { in: ROLES }

  scope :recently_seen, -> { order(last_seen_at: :desc, id: :desc) }
end
