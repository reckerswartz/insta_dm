module Instagram
  class Client
    class BulkMessageSendService
      def initialize(
        with_recoverable_session:,
        with_authenticated_driver:,
        find_profile_for_interaction:,
        dm_interaction_retry_pending:,
        send_direct_message_via_api:,
        mark_profile_dm_state:,
        apply_dm_state_from_send_result:,
        disconnected_session_error:,
        open_dm:,
        send_text_message_from_driver:
      )
        @with_recoverable_session = with_recoverable_session
        @with_authenticated_driver = with_authenticated_driver
        @find_profile_for_interaction = find_profile_for_interaction
        @dm_interaction_retry_pending = dm_interaction_retry_pending
        @send_direct_message_via_api = send_direct_message_via_api
        @mark_profile_dm_state = mark_profile_dm_state
        @apply_dm_state_from_send_result = apply_dm_state_from_send_result
        @disconnected_session_error = disconnected_session_error
        @open_dm = open_dm
        @send_text_message_from_driver = send_text_message_from_driver
      end

      def call(usernames:, message_text:)
        raise "Message cannot be blank" if message_text.to_s.strip.blank?

        with_recoverable_session.call(label: "send_messages") do
          sent = 0
          failed = 0
          fallback_usernames = []

          usernames.each do |username|
            begin
              profile = find_profile_for_interaction.call(username: username)
              if dm_interaction_retry_pending.call(profile)
                failed += 1
                next
              end

              api_result = send_direct_message_via_api.call(username: username, message_text: message_text)
              if api_result[:sent]
                mark_profile_dm_state.call(
                  profile: profile,
                  state: "messageable",
                  reason: "api_text_sent",
                  retry_after_at: nil
                )
                sent += 1
              else
                apply_dm_state_from_send_result.call(profile: profile, result: api_result)
                fallback_usernames << username
              end
            rescue StandardError => e
              raise if disconnected_session_error.call(e)

              fallback_usernames << username
            end
          end

          if fallback_usernames.any?
            with_authenticated_driver.call do |driver|
              fallback_usernames.each do |username|
                begin
                  next unless open_dm.call(driver, username)

                  send_text_message_from_driver.call(driver, message_text)
                  profile = find_profile_for_interaction.call(username: username)
                  mark_profile_dm_state.call(
                    profile: profile,
                    state: "messageable",
                    reason: "ui_fallback_sent",
                    retry_after_at: nil
                  )
                  sent += 1
                  sleep(0.8)
                rescue StandardError => e
                  raise if disconnected_session_error.call(e)

                  failed += 1
                end
              end
            end
          end

          unresolved = usernames.length - sent - failed
          failed += unresolved if unresolved.positive?

          {
            attempted: usernames.length,
            sent: sent,
            failed: failed
          }
        end
      end

      private

      attr_reader :with_recoverable_session,
        :with_authenticated_driver,
        :find_profile_for_interaction,
        :dm_interaction_retry_pending,
        :send_direct_message_via_api,
        :mark_profile_dm_state,
        :apply_dm_state_from_send_result,
        :disconnected_session_error,
        :open_dm,
        :send_text_message_from_driver
    end
  end
end
