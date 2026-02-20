module Instagram
  class Client
    class SyncFollowGraphService
      def initialize(
        account:,
        with_recoverable_session:,
        with_authenticated_driver:,
        collect_conversation_users:,
        collect_story_users:,
        collect_follow_list:,
        upsert_follow_list:
      )
        @account = account
        @with_recoverable_session = with_recoverable_session
        @with_authenticated_driver = with_authenticated_driver
        @collect_conversation_users = collect_conversation_users
        @collect_story_users = collect_story_users
        @collect_follow_list = collect_follow_list
        @upsert_follow_list = upsert_follow_list
      end

      def call
        with_recoverable_session.call(label: "sync_follow_graph") do
          with_authenticated_driver.call do |driver|
            raise "Instagram username must be set on the account before syncing" if account.username.blank?

            conversation_users = collect_conversation_users.call(driver)
            story_users = collect_story_users.call(driver)

            followers = collect_follow_list.call(driver, list_kind: :followers, profile_username: account.username)
            following = collect_follow_list.call(driver, list_kind: :following, profile_username: account.username)

            follower_usernames = followers.keys
            following_usernames = following.keys
            mutuals = follower_usernames & following_usernames

            InstagramProfile.transaction do
              account.instagram_profiles.update_all(following: false, follows_you: false)

              upsert_follow_list.call(followers, following_flag: false, follows_you_flag: true)
              upsert_follow_list.call(following, following_flag: true, follows_you_flag: false)

              account.instagram_profiles.where(username: mutuals).update_all(last_synced_at: Time.current)

              messageable_usernames = conversation_users.keys
              account.instagram_profiles.where(username: messageable_usernames).update_all(
                can_message: true,
                restriction_reason: nil,
                dm_interaction_state: "messageable",
                dm_interaction_reason: "inbox_thread_seen",
                dm_interaction_checked_at: Time.current,
                dm_interaction_retry_after_at: nil
              )
            end

            mark_story_visibility!(story_users: story_users)
            account.update!(last_synced_at: Time.current)

            {
              followers: follower_usernames.length,
              following: following_usernames.length,
              mutuals: mutuals.length,
              conversation_threads: conversation_users.length,
              profiles_total: account.instagram_profiles.count,
              story_tray_visible: story_users.length
            }
          end
        end
      end

      private

      attr_reader :account,
        :with_recoverable_session,
        :with_authenticated_driver,
        :collect_conversation_users,
        :collect_story_users,
        :collect_follow_list,
        :upsert_follow_list

      def mark_story_visibility!(story_users:)
        now = Time.current

        story_users.each_key do |username|
          profile = account.instagram_profiles.find_by(username: username)
          next unless profile

          profile.last_story_seen_at = now
          profile.recompute_last_active!
          profile.save!

          profile.record_event!(
            kind: "story_seen",
            external_id: "story_seen:#{now.utc.to_date.iso8601}",
            occurred_at: nil,
            metadata: { source: "home_story_tray" }
          )
        end
      end
    end
  end
end
