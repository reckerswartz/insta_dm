class EnqueueFeedAutoEngagementForAllAccountsJob < ApplicationJob
  queue_as :sync

  def perform(max_posts: 3, include_story: true, story_hold_seconds: 18)
    max_posts_i = max_posts.to_i.clamp(1, 10)
    include_story_bool = ActiveModel::Type::Boolean.new.cast(include_story)
    hold_seconds_i = story_hold_seconds.to_i.clamp(8, 40)

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      AutoEngageHomeFeedJob.perform_later(
        instagram_account_id: account.id,
        max_posts: max_posts_i,
        include_story: include_story_bool,
        story_hold_seconds: hold_seconds_i
      )
    rescue StandardError
      next
    end
  end
end
