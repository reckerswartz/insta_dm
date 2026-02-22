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
        upsert_follow_list:,
        follow_list_sync_context: nil
      )
        @account = account
        @with_recoverable_session = with_recoverable_session
        @with_authenticated_driver = with_authenticated_driver
        @collect_conversation_users = collect_conversation_users
        @collect_story_users = collect_story_users
        @collect_follow_list = collect_follow_list
        @upsert_follow_list = upsert_follow_list
        @follow_list_sync_context = follow_list_sync_context
      end

      def call
        with_recoverable_session.call(label: "sync_follow_graph") do
          with_authenticated_driver.call do |driver|
            raise "Instagram username must be set on the account before syncing" if account.username.blank?

            conversation_users = collect_conversation_users.call(driver)
            story_users = collect_story_users.call(driver)

            followers = collect_follow_list.call(driver, list_kind: :followers, profile_username: account.username)
            following = collect_follow_list.call(driver, list_kind: :following, profile_username: account.username)
            follower_context = follow_list_context_for(:followers)
            following_context = follow_list_context_for(:following)

            follower_usernames = followers.keys
            following_usernames = following.keys
            mutuals = follower_usernames & following_usernames

            InstagramProfile.transaction do
              upsert_follow_list.call(followers, following_flag: false, follows_you_flag: true)
              upsert_follow_list.call(following, following_flag: true, follows_you_flag: false)
              clear_missing_relationship_flags!(
                usernames: follower_usernames,
                flag_column: :follows_you,
                context: follower_context
              )
              clear_missing_relationship_flags!(
                usernames: following_usernames,
                flag_column: :following,
                context: following_context
              )

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
            followers_total = account.instagram_profiles.where(follows_you: true).count
            following_total = account.instagram_profiles.where(following: true).count
            mutuals_total = account.instagram_profiles.where(follows_you: true, following: true).count

            {
              followers: followers_total,
              following: following_total,
              mutuals: mutuals_total,
              followers_batch: follower_usernames.length,
              following_batch: following_usernames.length,
              mutuals_batch: mutuals.length,
              followers_complete: full_snapshot_context?(follower_context),
              following_complete: full_snapshot_context?(following_context),
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
        :upsert_follow_list,
        :follow_list_sync_context

      def follow_list_context_for(list_kind)
        return {} unless follow_list_sync_context.respond_to?(:call)

        context = follow_list_sync_context.call(list_kind)
        context.is_a?(Hash) ? context : {}
      rescue StandardError
        {}
      end

      def full_snapshot_context?(context)
        return false unless context.is_a?(Hash)

        raw_complete = context.key?(:complete) ? context[:complete] : context["complete"]
        raw_starting_cursor = context.key?(:starting_cursor) ? context[:starting_cursor] : context["starting_cursor"]
        complete = ActiveModel::Type::Boolean.new.cast(raw_complete)
        starting_cursor = raw_starting_cursor.to_s.presence
        complete && starting_cursor.blank?
      end

      def clear_missing_relationship_flags!(usernames:, flag_column:, context:)
        return unless full_snapshot_context?(context)

        scope = account.instagram_profiles.where(flag_column => true)
        scope = scope.where.not(username: usernames) if usernames.any?
        scope.update_all(flag_column => false, last_synced_at: Time.current)
      end

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
