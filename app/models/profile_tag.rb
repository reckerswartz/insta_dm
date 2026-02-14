class ProfileTag < ApplicationRecord
  has_many :instagram_profile_taggings, dependent: :destroy
  has_many :instagram_profiles, through: :instagram_profile_taggings

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  before_validation do
    self.name = name.to_s.strip.downcase
  end
end

