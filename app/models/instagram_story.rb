class InstagramStory < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile
  belongs_to :source_event, class_name: "InstagramProfileEvent", optional: true

  has_many :instagram_story_faces, dependent: :destroy
  has_one_attached :media

  validates :story_id, presence: true
  validates :processing_status, presence: true

  scope :processed, -> { where(processed: true) }
  scope :recent_first, -> { order(taken_at: :desc, id: :desc) }

  def video?
    media_type.to_s == "video" || media&.content_type.to_s.start_with?("video/")
  end

  def image?
    !video?
  end
end
