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

              recipient = account.recipients.find_or_initialize_by(username: username)
              recipient.display_name = conversation_users.dig(username, :display_name) || story_users.dig(username, :display_name) || username
              recipient.source = source_for.call(username, conversation_users, story_users)
              recipient.story_visible = story_users.key?(username)
              recipient.can_message = eligibility[:can_message]
              recipient.restriction_reason = eligibility[:restriction_reason]
              recipient.save!

              peer = account.conversation_peers.find_or_initialize_by(username: username)
              peer.display_name = recipient.display_name
              peer.last_message_at = Time.current
              peer.save!
            end

            account.update!(last_synced_at: Time.current)

            {
              recipients: account.recipients.count,
              eligible: account.recipients.eligible.count
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
