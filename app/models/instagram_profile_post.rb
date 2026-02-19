class InstagramProfilePost < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile
  has_many :instagram_profile_post_comments, dependent: :destroy
  has_many :instagram_post_faces, dependent: :destroy
  has_many :ai_analyses, as: :analyzable, dependent: :destroy

  has_one_attached :media
  has_one_attached :preview_image

  validates :shortcode, presence: true

  scope :recent_first, -> { order(taken_at: :desc, id: :desc) }
  scope :pending_ai, -> { where(ai_status: "pending") }

  def permalink_url
    permalink.presence || "#{Instagram::Client::INSTAGRAM_BASE_URL}/p/#{shortcode}/"
  end

  def latest_analysis
    ai_analyses.where(purpose: "post").recent_first.first
  end
end
