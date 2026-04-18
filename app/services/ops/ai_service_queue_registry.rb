module Ops
  class AiServiceQueueRegistry
    Service = Struct.new(
      :key,
      :name,
      :queue_name,
      :job_classes,
      :description,
      :category,
      :capsule_name,
      :concurrency_env,
      :concurrency_default,
      :concurrency_min,
      :concurrency_max,
      :nvidia_concurrency_default,
      :nvidia_concurrency_max,
      keyword_init: true
    ) do
      def queue_name_symbol
        queue_name.to_s.to_sym
      end

      def normalized_job_classes
        Array(job_classes).map(&:to_s).reject(&:blank?).uniq
      end
    end

    SERVICE_ROWS = [
      {
        key: "profile_analysis_runner",
        name: "Profile analysis",
        queue_name: "ai_profile_analysis_queue",
        job_classes: [ "AnalyzeInstagramProfileJob" ],
        description: "Runs profile-level AI analysis and demographic aggregation.",
        category: "analysis",
        capsule_name: "ai_profile_analysis_lane",
        concurrency_env: "SIDEKIQ_AI_PROFILE_ANALYSIS_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 6,
        nvidia_concurrency_default: 4,
        nvidia_concurrency_max: 12
      },
      {
        key: "post_analysis_runner",
        name: "Feed post analysis",
        queue_name: "ai_post_analysis_queue",
        job_classes: [ "AnalyzeInstagramPostJob" ],
        description: "Runs AI analysis for captured home/feed posts.",
        category: "analysis",
        capsule_name: "ai_post_analysis_lane",
        concurrency_env: "SIDEKIQ_AI_POST_ANALYSIS_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 6,
        nvidia_concurrency_default: 4,
        nvidia_concurrency_max: 12
      },
      {
        key: "profile_history_build",
        name: "Profile history build",
        queue_name: "ai_profile_history_queue",
        job_classes: [ "BuildInstagramProfileHistoryJob" ],
        description: "Builds and refreshes profile history readiness for AI tasks.",
        category: "orchestration",
        capsule_name: "ai_profile_history_lane",
        concurrency_env: "SIDEKIQ_AI_PROFILE_HISTORY_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4,
        nvidia_concurrency_default: 2,
        nvidia_concurrency_max: 6
      },
      {
        key: "llm_comment_generation",
        name: "Story LLM comment generation",
        queue_name: "ai_llm_comment_queue",
        job_classes: [ "GenerateLlmCommentJob", "GenerateStoryCommentFromPipelineJob" ],
        description: "Generates and ranks story comments with LLM services.",
        category: "generation",
        capsule_name: "ai_llm_comment_lane",
        concurrency_env: "SIDEKIQ_AI_LLM_COMMENT_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 6,
        nvidia_concurrency_default: 8,
        nvidia_concurrency_max: 16
      },
      {
        key: "post_comment_generation",
        name: "Post comment generation",
        queue_name: "ai_comment_generation_queue",
        job_classes: [ "GeneratePostCommentSuggestionsJob" ],
        description: "Generates post comment suggestions from analyzed post signals.",
        category: "generation",
        capsule_name: "ai_comment_generation_lane",
        concurrency_env: "SIDEKIQ_AI_COMMENT_GENERATION_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 6,
        nvidia_concurrency_default: 8,
        nvidia_concurrency_max: 16
      },
      {
        key: "pipeline_orchestration",
        name: "Post pipeline orchestration",
        queue_name: "ai_pipeline_orchestration_queue",
        job_classes: [ "AnalyzeInstagramProfilePostJob", "FinalizePostAnalysisPipelineJob", "FinalizeStoryCommentPipelineJob" ],
        description: "Coordinates AI pipeline steps and completion logic for profile posts.",
        category: "orchestration",
        capsule_name: "ai_pipeline_orchestration_lane",
        concurrency_env: "SIDEKIQ_AI_PIPELINE_ORCHESTRATION_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 5,
        nvidia_concurrency_default: 4,
        nvidia_concurrency_max: 10
      },
      {
        key: "profile_post_image_description",
        name: "Profile post image description",
        queue_name: "ai_profile_image_description_queue",
        job_classes: [ "AnalyzeInstagramProfilePostImageJob" ],
        description: "Generates profile post image descriptions as standalone AI jobs.",
        category: "analysis",
        capsule_name: "ai_profile_image_description_lane",
        concurrency_env: "SIDEKIQ_AI_PROFILE_IMAGE_DESCRIPTION_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 6,
        nvidia_concurrency_default: 6,
        nvidia_concurrency_max: 12
      },
      {
        key: "visual_analysis",
        name: "Visual analysis",
        queue_name: "ai_visual_queue",
        job_classes: [ "ProcessPostVisualAnalysisJob" ],
        description: "Runs vision analysis for post image payloads.",
        category: "analysis",
        capsule_name: "ai_visual_lane",
        concurrency_env: "SIDEKIQ_AI_VISUAL_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 5,
        nvidia_concurrency_default: 8,
        nvidia_concurrency_max: 16
      },
      {
        key: "face_analysis_secondary",
        name: "Face analysis (secondary)",
        queue_name: "ai_face_secondary_queue",
        job_classes: [],
        description: "Placeholder lane kept so existing AiServiceQueueMetrics snapshots still find the key; no longer receives work after Phase 12.",
        category: "analysis",
        capsule_name: "ai_face_secondary_lane",
        concurrency_env: "SIDEKIQ_AI_FACE_SECONDARY_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 3,
        nvidia_concurrency_default: 1,
        nvidia_concurrency_max: 3
      },
      {
        key: "metadata_tagging",
        name: "Metadata tagging",
        queue_name: "ai_metadata_queue",
        job_classes: [ "ProcessPostMetadataTaggingJob", "ProcessStoryCommentMetadataJob" ],
        description: "Applies metadata tagging and signal normalization after analysis.",
        category: "enrichment",
        capsule_name: "ai_metadata_lane",
        concurrency_env: "SIDEKIQ_AI_METADATA_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4,
        nvidia_concurrency_default: 4,
        nvidia_concurrency_max: 10
      },
      {
        key: "story_analysis",
        name: "Story analysis",
        queue_name: "story_analysis",
        job_classes: [ "AnalyzeInstagramStoryEventJob" ],
        description: "Runs AI analysis for downloaded story events.",
        category: "analysis",
        capsule_name: "story_analysis_lane",
        concurrency_env: "SIDEKIQ_STORY_ANALYSIS_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4,
        nvidia_concurrency_default: 4,
        nvidia_concurrency_max: 10
      },
      {
        key: "story_engagement_actions",
        name: "Story engagement actions",
        queue_name: "story_engagement_actions",
        job_classes: [ "SendStoryReplyEngagementJob" ],
        description: "Runs async eligibility-check and story reply send actions.",
        category: "engagement",
        capsule_name: "story_engagement_actions_lane",
        concurrency_env: "SIDEKIQ_STORY_ENGAGEMENT_ACTIONS_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4,
        nvidia_concurrency_default: 1,
        nvidia_concurrency_max: 4
      }
    ].freeze

    class << self
      def services
        @services ||= SERVICE_ROWS.map { |row| Service.new(**row) }
      end

      def service_for(key)
        services.find { |service| service.key.to_s == key.to_s }
      end

      def queue_name_for(key)
        service_for(key)&.queue_name.to_s
      end

      def queue_symbol_for(key)
        value = queue_name_for(key)
        return nil if value.blank?

        value.to_sym
      end

      def service_for_queue(queue_name)
        queue = queue_name.to_s
        return nil if queue.blank?

        services.find { |service| service.queue_name.to_s == queue }
      end

      def service_for_job_class(job_class_name)
        klass = job_class_name.to_s
        return nil if klass.blank?

        services.find { |service| service.normalized_job_classes.include?(klass) }
      end

      def ai_queue_names
        services.map { |service| service.queue_name.to_s }.reject(&:blank?).uniq
      end

      def sidekiq_capsules
        services.map do |service|
          {
            capsule_name: service.capsule_name.to_s,
            queue_name: service.queue_name.to_s,
            concurrency: concurrency_for(service: service)
          }
        end
      end

      def concurrency_for(service:)
        # Phase 4.6: when the NVIDIA provider is actively serving AI
        # traffic (remote inference), we can safely run many more
        # concurrent jobs per lane than the legacy local Ollama stack
        # could support. Each service row carries both the legacy
        # concurrency_* and nvidia_concurrency_* tier; we pick the
        # right tier based on the live AiProviderSetting state.
        use_nvidia_tier = nvidia_concurrency_tier_active?
        default_value = (use_nvidia_tier ? service.nvidia_concurrency_default : service.concurrency_default).to_i
        min_value = service.concurrency_min.to_i
        max_value = (use_nvidia_tier ? service.nvidia_concurrency_max : service.concurrency_max).to_i

        # Fall back to legacy values when the row doesn't carry an
        # nvidia_concurrency_* value (e.g. for new services that haven't
        # been tuned yet).
        default_value = service.concurrency_default.to_i if default_value.zero?
        max_value = service.concurrency_max.to_i if max_value.zero?

        ENV.fetch(service.concurrency_env.to_s, default_value).to_i.clamp(min_value, max_value)
      rescue StandardError
        default_value.to_i.clamp(service.concurrency_min.to_i, service.concurrency_max.to_i)
      end

      # True once any nvidia text role is enabled with a key. Cached for
      # the life of the Sidekiq process so capsule construction doesn't
      # hit the DB on every queue spin-up. The cache is reset on process
      # reload (e.g. sidekiqctl restart) which is the normal way ops
      # roll out a provider change.
      def nvidia_concurrency_tier_active?
        return @nvidia_tier_cached unless @nvidia_tier_cached.nil?

        @nvidia_tier_cached =
          begin
            AiProviderSetting
              .for_provider("nvidia")
              .where(role: %w[text_quality text_fast], enabled: true)
              .any? { |s| s.api_key_present? }
          rescue StandardError
            false
          end
      end

      # Public reset hook for tests + ops toggling nvidia via
      # `rake ai:nvidia:enable` during a running process.
      def reset_nvidia_tier_cache!
        @nvidia_tier_cached = nil
      end
    end
  end
end
