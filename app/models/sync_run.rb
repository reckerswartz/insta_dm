class SyncRun < ApplicationRecord
  belongs_to :instagram_account

  validates :kind, presence: true
  validates :status, presence: true

  def stats
    return {} if stats_json.blank?

    JSON.parse(stats_json)
  rescue JSON::ParserError
    {}
  end

  def stats=(value)
    self.stats_json = value.to_h.to_json
  end
end

