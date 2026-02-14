class InstagramProfileTagging < ApplicationRecord
  belongs_to :instagram_profile
  belongs_to :profile_tag

  validates :instagram_profile_id, uniqueness: { scope: :profile_tag_id }
end

