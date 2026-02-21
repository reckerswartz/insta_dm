require "rails_helper"

RSpec.describe Ops::AiServiceQueueRegistry do
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
    expect(described_class.service_for_job_class("GeneratePostCommentSuggestionsJob")&.key).to eq("post_comment_generation")
  end

  it "routes key jobs to non-overlapping queue names" do
    expect(AnalyzeInstagramProfileJob.queue_name).to eq("ai_profile_analysis_queue")
    expect(AnalyzeInstagramPostJob.queue_name).to eq("ai_post_analysis_queue")
    expect(BuildInstagramProfileHistoryJob.queue_name).to eq("ai_profile_history_queue")
    expect(GenerateLlmCommentJob.queue_name).to eq("ai_llm_comment_queue")
    expect(GeneratePostCommentSuggestionsJob.queue_name).to eq("ai_comment_generation_queue")
    expect(AnalyzeInstagramProfilePostImageJob.queue_name).to eq("ai_profile_image_description_queue")
    expect(AnalyzeInstagramProfilePostJob.queue_name).to eq("ai_pipeline_orchestration_queue")
    expect(FinalizePostAnalysisPipelineJob.queue_name).to eq("ai_pipeline_orchestration_queue")
    expect(WorkspaceProcessActionsTodoPostJob.queue_name).to eq("workspace_actions_queue")
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
  end
end
