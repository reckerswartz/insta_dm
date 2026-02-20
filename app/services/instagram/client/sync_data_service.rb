module Instagram
  class Client
    class SyncDataService
      def initialize(
        account:,
        with_recoverable_session:,
        with_authenticated_driver:,
        collect_conversation_users:,
        collect_story_users:,
        fetch_eligibility:,
        source_for:
      )
        @account = account
        @with_recoverable_session = with_recoverable_session
        @with_authenticated_driver = with_authenticated_driver
        @collect_conversation_users = collect_conversation_users
        @collect_story_users = collect_story_users
        @fetch_eligibility = fetch_eligibility
        @source_for = source_for
      end

      def call
        with_recoverable_session.call(label: "sync") do
          with_authenticated_driver.call do |driver|
            conversation_users = collect_conversation_users.call(driver)
            story_users = collect_story_users.call(driver)

            usernames = (conversation_users.keys + story_users.keys).uniq

            usernames.each do |username|
              eligibility =
                if conversation_users.key?(username)
                  { can_message: true, restriction_reason: nil }
                else
                  fetch_eligibility.call(driver, username)
                end

              display_name = conversation_users.dig(username, :display_name) || story_users.dig(username, :display_name) || username

              profile = account.instagram_profiles.find_or_initialize_by(username: username)
              profile.display_name = display_name
              profile.can_message = eligibility[:can_message]
              profile.restriction_reason = eligibility[:restriction_reason]
              profile.dm_interaction_state = eligibility[:can_message] ? "messageable" : "unavailable"
              profile.dm_interaction_reason = eligibility[:restriction_reason].to_s.presence
              profile.dm_interaction_checked_at = Time.current
              profile.last_story_seen_at = Time.current if story_users.key?(username)
              profile.last_synced_at = Time.current
              profile.recompute_last_active!
              profile.save!

              profile.record_event!(
                kind: "story_seen",
                external_id: "story_seen:#{Time.current.utc.to_date.iso8601}",
                metadata: { source: source_for.call(username, conversation_users, story_users) }
              ) if story_users.key?(username)

              peer = account.conversation_peers.find_or_initialize_by(username: username)
              peer.display_name = display_name
              peer.last_message_at = Time.current
              peer.save!
            end

            account.update!(last_synced_at: Time.current)

            {
              recipients: account.conversation_peers.count,
              eligible: account.instagram_profiles.where(can_message: true).count
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
        :fetch_eligibility,
        :source_for
    end
  end
end
