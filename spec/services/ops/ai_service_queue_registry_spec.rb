require "rails_helper"

RSpec.describe Ops::AiServiceQueueRegistry do
  before do
    described_class.reset_nvidia_tier_cache!
  end

  it "maps AI job classes to dedicated service queues" do
    expect(described_class.queue_name_for(:profile_analysis_runner)).to eq("ai_profile_analysis_queue")
    expect(described_class.queue_name_for(:post_analysis_runner)).to eq("ai_post_analysis_queue")
    expect(described_class.queue_name_for(:profile_history_build)).to eq("ai_profile_history_queue")
    expect(described_class.queue_name_for(:llm_comment_generation)).to eq("ai_llm_comment_queue")
    expect(described_class.queue_name_for(:post_comment_generation)).to eq("ai_comment_generation_queue")
  end

  it "returns service metadata by job class" do
    expect(described_class.service_for_job_class("AnalyzeInstagramProfileJob")&.key).to eq("profile_analysis_runner")
    expect(described_class.service_for_job_class("AnalyzeInstagramPostJob")&.key).to eq("post_analysis_runner")
    expect(described_class.service_for_job_class("GenerateLlmCommentJob")&.key).to eq("llm_comment_generation")
    expect(described_class.service_for_job_class("GenerateStoryCommentFromPipelineJob")&.key).to eq("llm_comment_generation")
    expect(described_class.service_for_job_class("GeneratePostCommentSuggestionsJob")&.key).to eq("post_comment_generation")
  end

  it "routes key jobs to non-overlapping queue names" do
    expect(AnalyzeInstagramProfileJob.queue_name).to eq("ai_profile_analysis_queue")
    expect(AnalyzeInstagramPostJob.queue_name).to eq("ai_post_analysis_queue")
    expect(BuildInstagramProfileHistoryJob.queue_name).to eq("ai_profile_history_queue")
    expect(GenerateLlmCommentJob.queue_name).to eq("ai_llm_comment_queue")
    expect(GenerateStoryCommentFromPipelineJob.queue_name).to eq("ai_llm_comment_queue")
    expect(GeneratePostCommentSuggestionsJob.queue_name).to eq("ai_comment_generation_queue")
    expect(AnalyzeInstagramProfilePostImageJob.queue_name).to eq("ai_profile_image_description_queue")
    expect(AnalyzeInstagramProfilePostJob.queue_name).to eq("ai_pipeline_orchestration_queue")
    expect(FinalizePostAnalysisPipelineJob.queue_name).to eq("ai_pipeline_orchestration_queue")
    expect(ProcessPostVisualAnalysisJob.queue_name).to eq("ai_visual_queue")
    expect(ProcessPostMetadataTaggingJob.queue_name).to eq("ai_metadata_queue")
    expect(WorkspaceProcessActionsTodoPostJob.queue_name).to eq("workspace_actions_queue")
    # face_analysis_secondary is kept as a placeholder lane after Phase 12
    # so AiServiceQueueMetrics snapshots still find the key; no jobs route
    # to it any more.
    expect(described_class.queue_name_for(:face_analysis_secondary)).to eq("ai_face_secondary_queue")
  end

  it "keeps every registered job class aligned with its service queue" do
    mismatches = described_class.services.flat_map do |service|
      service.normalized_job_classes.filter_map do |job_class_name|
        job_class = job_class_name.safe_constantize
        next "#{job_class_name}:missing_class" unless job_class
        next if job_class.queue_name.to_s == service.queue_name.to_s

        "#{job_class_name}:#{job_class.queue_name}->#{service.queue_name}"
      end
    end

    expect(mismatches).to eq([])
  end

  it "builds sidekiq capsule definitions from registry entries" do
    capsules = described_class.sidekiq_capsules

    expect(capsules).to include(
      hash_including(
        capsule_name: "ai_profile_analysis_lane",
        queue_name: "ai_profile_analysis_queue"
      )
    )
    expect(capsules).to include(
      hash_including(
        capsule_name: "ai_llm_comment_lane",
        queue_name: "ai_llm_comment_queue"
      )
    )
    expect(capsules).to include(
      hash_including(
        capsule_name: "ai_face_secondary_lane",
        queue_name: "ai_face_secondary_queue"
      )
    )
  end

  # --- Phase 4.6: NVIDIA concurrency tier --------------------------------

  describe "Phase 4.6 NVIDIA concurrency tier" do
    let(:service) { described_class.service_for("llm_comment_generation") }

    it "returns the legacy tier when NVIDIA is not active" do
      Ai::ProviderRegistry.ensure_settings!
      AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
      described_class.reset_nvidia_tier_cache!

      expect(described_class.concurrency_for(service: service)).to eq(service.concurrency_default)
    end

    it "returns the nvidia tier when any nvidia text role is enabled with a key" do
      Ai::ProviderRegistry.ensure_settings!
      AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
      AiProviderSetting.for_provider("nvidia")
                       .for_role("text_quality").first!
                       .update!(enabled: true, api_key: "nvapi-test")
      described_class.reset_nvidia_tier_cache!

      expect(described_class.concurrency_for(service: service)).to eq(service.nvidia_concurrency_default)
    end

    it "clamps to nvidia_concurrency_max when the env var exceeds the tier cap" do
      Ai::ProviderRegistry.ensure_settings!
      AiProviderSetting.for_provider("nvidia")
                       .for_role("text_quality").first!
                       .update!(enabled: true, api_key: "nvapi-test")
      described_class.reset_nvidia_tier_cache!

      env_key = service.concurrency_env
      begin
        ENV[env_key] = "9999"
        expect(described_class.concurrency_for(service: service)).to eq(service.nvidia_concurrency_max)
      ensure
        ENV.delete(env_key)
      end
    end

    it "keeps deprecated lanes (face/OCR/video) at 1 even with NVIDIA enabled" do
      # Phase 12 deleted the face_analysis / face_refresh / ocr_analysis
      # / video_analysis lanes outright. The only survivor is the
      # placeholder `face_analysis_secondary` key which we keep so
      # queue-metrics snapshots from earlier deploys don't raise -- it
      # has `job_classes: []` and nothing routes to it.
      s = described_class.service_for("face_analysis_secondary")
      expect(described_class.concurrency_for(service: s)).to eq(1)
    end

    it "defines bumped values for every active AI lane" do
      active_keys = %w[
        profile_analysis_runner post_analysis_runner profile_history_build
        llm_comment_generation post_comment_generation pipeline_orchestration
        profile_post_image_description visual_analysis metadata_tagging
        story_analysis
      ]
      active_keys.each do |key|
        s = described_class.service_for(key)
        expect(s.nvidia_concurrency_default.to_i).to be > s.concurrency_default.to_i,
          "expected #{key} nvidia_concurrency_default (#{s.nvidia_concurrency_default}) > local (#{s.concurrency_default})"
        expect(s.nvidia_concurrency_max.to_i).to be >= s.concurrency_max.to_i
      end
    end
  end
end
