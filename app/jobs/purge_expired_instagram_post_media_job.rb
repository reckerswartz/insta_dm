class PurgeExpiredInstagramPostMediaJob < ApplicationJob
  queue_as :profiles

  def perform(limit: 200)
    now = Time.current
    scope = InstagramPost.where("purge_at IS NOT NULL AND purge_at <= ?", now).order(purge_at: :asc).limit(limit.to_i.clamp(1, 2000))

    scope.find_each do |post|
      begin
        post.media.purge if post.media.attached?
      rescue StandardError
        nil
      end
      post.update_columns(purge_at: nil) # avoid reprocessing
    end
  end
end

