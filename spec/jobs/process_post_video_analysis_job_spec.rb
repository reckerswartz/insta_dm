require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "ProcessPostVideoAnalysisJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      {
        allow: true,
        reason: nil,
        retry_in_seconds: 0,
        snapshot: {}
      }
    )
  end

  it "persists enriched video context into analysis and metadata" do
    account, profile, post, run_id = build_video_pipeline_post
    extractor = instance_double(PostVideoContextExtractionService)
    allow(PostVideoContextExtractionService).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:extract).and_return(
      {
        skipped: false,
        processing_mode: "static_image",
        static: true,
        semantic_route: "image",
        duration_seconds: 6.2,
        has_audio: true,
        transcript: "Sunny drive playlist",
        topics: [ "car", "sunset" ],
        objects: [ "vehicle" ],
        scenes: [ { "type" => "single_frame" } ],
        hashtags: [ "#roadtrip" ],
        mentions: [ "@friend" ],
        profile_handles: [ "friend.profile" ],
        ocr_text: "ROAD TRIP",
        ocr_blocks: [ { "text" => "ROAD TRIP" } ],
        context_summary: "Static visual video detected and routed through image-style analysis.",
        metadata: {
          frame_change_detection: { max_mean_diff: 0.2 }
        }
      }
    )

    assert_enqueued_jobs 1, only: FinalizePostAnalysisPipelineJob do
      ProcessPostVideoAnalysisJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id
      )
    end

    post.reload
    assert_equal "static_image", post.analysis["video_processing_mode"]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.analysis["video_static_detected"])
    assert_equal "image", post.analysis["video_semantic_route"]
    assert_equal "Sunny drive playlist", post.analysis["transcript"]
    assert_includes Array(post.analysis["topics"]), "car"
    assert_includes Array(post.analysis["hashtags"]), "#roadtrip"
    assert_equal "ROAD TRIP", post.analysis["ocr_text"]

    video_meta = post.metadata["video_processing"]
    assert_equal "image", video_meta["semantic_route"]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(video_meta["has_audio"])
    assert_equal "Sunny drive playlist", video_meta["transcript"]
    assert_equal "Static visual video detected and routed through image-style analysis.", video_meta["context_summary"]

    step = post.metadata.dig("ai_pipeline", "steps", "video")
    assert_equal "succeeded", step["status"]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(step.dig("result", "transcript_present"))
    assert_equal "image", step.dig("result", "semantic_route")
  end

  it "records skipped video extraction results without failing the step" do
    account, profile, post, run_id = build_video_pipeline_post
    extractor = instance_double(PostVideoContextExtractionService)
    allow(PostVideoContextExtractionService).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:extract).and_return(
      {
        skipped: true,
        processing_mode: "dynamic_video",
        static: false,
        semantic_route: "video",
        duration_seconds: nil,
        has_audio: nil,
        transcript: nil,
        topics: [],
        objects: [],
        scenes: [],
        hashtags: [],
        mentions: [],
        profile_handles: [],
        ocr_text: nil,
        ocr_blocks: [],
        context_summary: nil,
        metadata: { reason: "video_too_large_for_context_extraction" }
      }
    )

    ProcessPostVideoAnalysisJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id
    )

    post.reload
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.metadata.dig("video_processing", "skipped"))
    assert_equal "video_too_large_for_context_extraction", post.metadata.dig("video_processing", "metadata", "reason")
    assert_equal "succeeded", post.metadata.dig("ai_pipeline", "steps", "video", "status")
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.metadata.dig("ai_pipeline", "steps", "video", "result", "skipped"))
  end

  it "reuses cached video extraction for matching media fingerprint" do
    account, profile, post, run_id = build_video_pipeline_post
    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    payload = builder.video_payload
    fingerprint = builder.media_fingerprint(media: payload)

    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    metadata["video_processing"] = {
      "skipped" => false,
      "processing_mode" => "dynamic_video",
      "static" => false,
      "semantic_route" => "video",
      "duration_seconds" => 8.5,
      "has_audio" => true,
      "transcript" => "Already cached transcript",
      "topics" => [ "cached_topic" ],
      "objects" => [ "cached_object" ],
      "scenes" => [ { "type" => "scene_change" } ],
      "hashtags" => [ "#cached" ],
      "mentions" => [ "@cached" ],
      "profile_handles" => [ "cached.profile" ],
      "ocr_text" => "CACHED",
      "ocr_blocks" => [ { "text" => "CACHED" } ],
      "context_summary" => "Cached summary",
      "metadata" => { "source" => "cached" },
      "media_fingerprint" => fingerprint,
      "extraction_profile" => ProcessPostVideoAnalysisJob::VIDEO_EXTRACTION_PROFILE
    }
    post.update!(metadata: metadata)

    extractor = instance_double(PostVideoContextExtractionService)
    allow(PostVideoContextExtractionService).to receive(:new).and_return(extractor)
    expect(extractor).not_to receive(:extract)

    ProcessPostVideoAnalysisJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id
    )

    post.reload
    assert_equal "Already cached transcript", post.metadata.dig("video_processing", "transcript")
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.metadata.dig("video_processing", "cache", "hit"))
    assert_equal "post_metadata_video_processing", post.metadata.dig("video_processing", "cache", "source")
    assert_equal "succeeded", post.metadata.dig("ai_pipeline", "steps", "video", "status")
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.metadata.dig("ai_pipeline", "steps", "video", "result", "cache_hit"))
  end

  def build_video_pipeline_post
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 1200
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "pending",
      analysis: { "image_description" => "Road photo." },
      metadata: {}
    )
    post.media.attach(
      io: StringIO.new("\x00\x00\x00\x18ftypmp42video-binary"),
      filename: "post_video.mp4",
      content_type: "video/mp4"
    )

    pipeline_state = Ai::PostAnalysisPipelineState.new(post: post)
    run_id = pipeline_state.start!(
      task_flags: {
        analyze_visual: false,
        analyze_faces: false,
        run_ocr: false,
        run_video: true,
        run_metadata: false
      },
      source_job: self.class.name
    )

    [ account, profile, post, run_id ]
  end
end
