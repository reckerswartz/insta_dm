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
  after_commit :broadcast_posts_table_refresh

  def permalink
    "#{Instagram::Client::INSTAGRAM_BASE_URL}/p/#{shortcode}/"
  end

  private

  def broadcast_posts_table_refresh
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "posts_table_changed",
      account_id: instagram_account_id,
      payload: { post_id: id },
      throttle_key: "posts_table_changed"
    )
  end
end
