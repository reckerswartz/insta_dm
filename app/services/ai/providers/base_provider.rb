module Ai
  module Providers
    class BaseProvider
      attr_reader :setting

      def initialize(setting: nil)
        @setting = setting
      end

      def key
        raise NotImplementedError
      end

      def display_name
        setting&.display_name || key.to_s.humanize
      end

      def supports_profile?
        false
      end

      def supports_post_image?
        false
      end

      def supports_post_video?
        false
      end

      def available?
        setting&.enabled == true && setting&.api_key_present?
      end

      def preferred_model
        effective_model
      end

      def test_key!
        raise NotImplementedError
      end

      def analyze_profile!(_profile_payload:, _media: nil)
        raise NotImplementedError
      end

      def analyze_post!(_post_payload:, _media: nil)
        raise NotImplementedError
      end

      protected

      def ensure_api_key!
        return setting.effective_api_key if setting&.effective_api_key.to_s.present?

        raise "Missing API key for #{display_name}"
      end

      def effective_model
        setting&.effective_model.to_s
      end
    end
  end
end
