class InstagramPost < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile, optional: true

  has_one_attached :media
  has_many :ai_analyses, as: :analyzable, dependent: :destroy
  has_many :instagram_post_insights, dependent: :destroy
  has_many :instagram_post_entities, dependent: :destroy

  validates :shortcode, presence: true
  validates :detected_at, presence: true
  validates :status, presence: true

  scope :recent_first, -> { order(detected_at: :desc, id: :desc) }

  def permalink
    "#{Instagram::Client::INSTAGRAM_BASE_URL}/p/#{shortcode}/"
  end
end
