module Ai
  class ProfileAutoTagger
    TAG_KEYS = %w[personal_user friend female_friend male_friend relative page excluded automatic_reply].freeze

    class << self
      def sync_from_post_analysis!(profile:, analysis:)
        return unless profile
        return unless analysis.is_a?(Hash)

        inferred = infer_tags(profile: profile, analysis: analysis)
        return if inferred.empty?

        existing = profile.profile_tags.pluck(:name)
        desired = (existing + inferred).uniq
        tags = desired.filter_map do |name|
          next unless TAG_KEYS.include?(name.to_s)
          ProfileTag.find_or_create_by!(name: name.to_s)
        end
        profile.profile_tags = tags
        profile.save!
      rescue StandardError
        nil
      end

      private

      def infer_tags(profile:, analysis:)
        tags = []
        author_type = analysis["author_type"].to_s
        relevant = analysis["relevant"]
        confidence = analysis["confidence"].to_f

        case author_type
        when "page"
          tags << "page"
        when "relative"
          tags << "relative"
        when "friend"
          tags << "friend"
        when "personal_user"
          tags << "personal_user"
        end

        tags << "excluded" if relevant == false && confidence >= 0.6

        if relevant == true && confidence >= 0.65 && profile.can_message == true
          tags << "automatic_reply"
        end

        tags.uniq
      end
    end
  end
end
