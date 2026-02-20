module Instagram
  class Client
    class SingleMessageSendService
      def initialize(
        with_recoverable_session:,
        with_authenticated_driver:,
        with_task_capture:,
        find_profile_for_interaction:,
        dm_interaction_retry_pending:,
        send_direct_message_via_api:,
        mark_profile_dm_state:,
        apply_dm_state_from_send_result:,
        open_dm:,
        send_text_message_from_driver:
      )
        @with_recoverable_session = with_recoverable_session
        @with_authenticated_driver = with_authenticated_driver
        @with_task_capture = with_task_capture
        @find_profile_for_interaction = find_profile_for_interaction
        @dm_interaction_retry_pending = dm_interaction_retry_pending
        @send_direct_message_via_api = send_direct_message_via_api
        @mark_profile_dm_state = mark_profile_dm_state
        @apply_dm_state_from_send_result = apply_dm_state_from_send_result
        @open_dm = open_dm
        @send_text_message_from_driver = send_text_message_from_driver
      end

      def call(username:, message_text:)
        with_recoverable_session.call(label: "send_message") do
          profile = find_profile_for_interaction.call(username: username)
          if dm_interaction_retry_pending.call(profile)
            retry_after = profile&.dm_interaction_retry_after_at
            stamp = retry_after&.utc&.iso8601
            raise "DM retry pending for #{username}#{stamp.present? ? " until #{stamp}" : ""}"
          end

          api_result = send_direct_message_via_api.call(username: username, message_text: message_text)
          if api_result[:sent]
            mark_profile_dm_state.call(
              profile: profile,
              state: "messageable",
              reason: "api_text_sent",
              retry_after_at: nil
            )
            return true
          end

          apply_dm_state_from_send_result.call(profile: profile, result: api_result)

          with_authenticated_driver.call do |driver|
            raise "Message cannot be blank" if message_text.to_s.strip.blank?
            raise "Username cannot be blank" if username.to_s.strip.blank?

            ok =
              with_task_capture.call(driver: driver, task_name: "dm_open", meta: { username: username }) do
                open_dm.call(driver, username)
              end
            raise "Unable to open DM for #{username}" unless ok

            with_task_capture.call(
              driver: driver,
              task_name: "dm_send_text",
              meta: {
                username: username,
                message_preview: message_text.to_s.strip.byteslice(0, 80),
                api_fallback_reason: api_result[:reason].to_s
              }
            ) do
              send_text_message_from_driver.call(driver, message_text.to_s, expected_username: username)
            end
            mark_profile_dm_state.call(
              profile: profile,
              state: "messageable",
              reason: "ui_fallback_sent",
              retry_after_at: nil
            )
            sleep(0.6)
            true
          end
        end
      end

      private

      attr_reader :with_recoverable_session,
        :with_authenticated_driver,
        :with_task_capture,
        :find_profile_for_interaction,
        :dm_interaction_retry_pending,
        :send_direct_message_via_api,
        :mark_profile_dm_state,
        :apply_dm_state_from_send_result,
        :open_dm,
        :send_text_message_from_driver
    end
  end
end
