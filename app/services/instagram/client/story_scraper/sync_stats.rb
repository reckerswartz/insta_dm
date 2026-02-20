module Instagram
  class Client
    module StoryScraper
      class SyncStats < Hash
        DEFAULT_COUNTERS = {
          stories_visited: 0,
          downloaded: 0,
          analyzed: 0,
          commented: 0,
          reacted: 0,
          skipped_video: 0,
          skipped_not_tagged: 0,
          skipped_ads: 0,
          skipped_invalid_media: 0,
          skipped_unreplyable: 0,
          skipped_out_of_network: 0,
          skipped_interaction_retry: 0,
          skipped_reshared_external_link: 0,
          failed: 0
        }.freeze

        def initialize(overrides = {})
          super()
          merge!(DEFAULT_COUNTERS)
          merge!(overrides.transform_keys(&:to_sym))
        end

        def increment!(key, by: 1)
          self[key.to_sym] = self[key.to_sym].to_i + by.to_i
        end
      end
    end
  end
end
