class InstagramPostFace < ApplicationRecord
  ROLES = %w[primary_user secondary_person unknown].freeze

  belongs_to :instagram_profile_post
  belongs_to :instagram_story_person, optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
end
