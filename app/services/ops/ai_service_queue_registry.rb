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
        key: "legacy_ai_default",
        name: "Legacy AI default",
        queue_name: "ai",
        job_classes: [],
        description: "Compatibility lane for previously enqueued AI jobs.",
        category: "compatibility",
        capsule_name: "ai_legacy_lane",
        concurrency_env: "SIDEKIQ_AI_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4
      },
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
        concurrency_max: 6
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
        concurrency_default: 2,
        concurrency_min: 1,
        concurrency_max: 6
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
        concurrency_max: 4
      },
      {
        key: "llm_comment_generation",
        name: "Story LLM comment generation",
        queue_name: "ai_llm_comment_queue",
        job_classes: [ "GenerateLlmCommentJob" ],
        description: "Generates and ranks story comments with LLM services.",
        category: "generation",
        capsule_name: "ai_llm_comment_lane",
        concurrency_env: "SIDEKIQ_AI_LLM_COMMENT_CONCURRENCY",
        concurrency_default: 2,
        concurrency_min: 1,
        concurrency_max: 6
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
        concurrency_max: 6
      },
      {
        key: "pipeline_orchestration",
        name: "Post pipeline orchestration",
        queue_name: "ai_pipeline_orchestration_queue",
        job_classes: [ "AnalyzeInstagramProfilePostJob", "FinalizePostAnalysisPipelineJob" ],
        description: "Coordinates AI pipeline steps and completion logic for profile posts.",
        category: "orchestration",
        capsule_name: "ai_pipeline_orchestration_lane",
        concurrency_env: "SIDEKIQ_AI_PIPELINE_ORCHESTRATION_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 5
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
        concurrency_max: 6
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
        concurrency_default: 2,
        concurrency_min: 1,
        concurrency_max: 5
      },
      {
        key: "face_analysis",
        name: "Face analysis",
        queue_name: "ai_face_queue",
        job_classes: [ "ProcessPostFaceAnalysisJob" ],
        description: "Runs face detection and identity matching workloads.",
        category: "analysis",
        capsule_name: "ai_face_lane",
        concurrency_env: "SIDEKIQ_AI_FACE_CONCURRENCY",
        concurrency_default: 2,
        concurrency_min: 1,
        concurrency_max: 5
      },
      {
        key: "face_refresh",
        name: "Face refresh",
        queue_name: "ai_face_refresh_queue",
        job_classes: [ "RefreshProfilePostFaceIdentityJob" ],
        description: "Refreshes face identity evidence for profile history accuracy.",
        category: "analysis",
        capsule_name: "ai_face_refresh_lane",
        concurrency_env: "SIDEKIQ_AI_FACE_REFRESH_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 3
      },
      {
        key: "ocr_analysis",
        name: "OCR analysis",
        queue_name: "ai_ocr_queue",
        job_classes: [ "ProcessPostOcrAnalysisJob" ],
        description: "Runs OCR extraction for post media.",
        category: "analysis",
        capsule_name: "ai_ocr_lane",
        concurrency_env: "SIDEKIQ_AI_OCR_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4
      },
      {
        key: "video_analysis",
        name: "Video analysis",
        queue_name: "video_processing_queue",
        job_classes: [ "ProcessPostVideoAnalysisJob" ],
        description: "Runs video context extraction workloads.",
        category: "analysis",
        capsule_name: "ai_video_lane",
        concurrency_env: "SIDEKIQ_AI_VIDEO_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4
      },
      {
        key: "metadata_tagging",
        name: "Metadata tagging",
        queue_name: "ai_metadata_queue",
        job_classes: [ "ProcessPostMetadataTaggingJob" ],
        description: "Applies metadata tagging and signal normalization after analysis.",
        category: "enrichment",
        capsule_name: "ai_metadata_lane",
        concurrency_env: "SIDEKIQ_AI_METADATA_CONCURRENCY",
        concurrency_default: 1,
        concurrency_min: 1,
        concurrency_max: 4
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
        concurrency_max: 4
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
        default_value = service.concurrency_default.to_i
        min_value = service.concurrency_min.to_i
        max_value = service.concurrency_max.to_i

        ENV.fetch(service.concurrency_env.to_s, default_value).to_i.clamp(min_value, max_value)
      rescue StandardError
        default_value.clamp(min_value, max_value)
      end
    end
  end
end
