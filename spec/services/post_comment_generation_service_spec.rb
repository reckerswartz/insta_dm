require "rails_helper"
require "securerandom"

RSpec.describe Ai::PostCommentGenerationService do
  before do
    allow(Ai::CommentRelevanceScorer).to receive(:annotate_llm_order_with_breakdown) do |suggestions:, **_kwargs|
      Array(suggestions).map.with_index do |text, index|
        {
          comment: text.to_s,
          score: (1.65 - (index * 0.05)).round(3),
          relevance_score: (1.6 - (index * 0.05)).round(3),
          llm_rank: index + 1,
          llm_order_bonus: 0.05,
          auto_post_eligible: true,
          confidence_level: "medium",
          factors: {}
        }
      end
    end
  end

  class FakePreparationService
    def initialize(payload)
      @payload = payload
    end

    def prepare!(force: false)
      @payload
    end
  end

  class FakeCommentGenerator
    attr_reader :calls, :last_kwargs

    def initialize(result)
      @result = result
      @calls = 0
    end

    def generate!(**kwargs)
      @calls += 1
      @last_kwargs = kwargs
      @result
    end
  end

  def build_account_profile_post
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      ai_status: "pending",
      caption: "My city walk today with friends.",
      analysis: {
        "image_description" => "A person in a city street.",
        "topics" => [ "person", "city" ],
        "face_summary" => { "face_count" => 1, "owner_faces_count" => 1 }
      },
      metadata: {}
    )

    [ account, profile, post ]
  end

  it "keeps generating comments when face/text evidence is missing but visual context exists" do
    account, profile, post = build_account_profile_post
    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are not analyzed yet."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [ "Great framing on this city moment." ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal 1, Array(post.analysis["comment_suggestions"]).length
    assert_equal 1, generator.calls
    assert_equal "enabled_history_pending", post.metadata.dig("comment_generation_policy", "status")
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "history"
    refute_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "face"
    refute_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "text_context"
  end

  it "generates comments when visual context exists and history is ready" do
    account, profile, post = build_account_profile_post
    post.update!(
      metadata: {
        "face_recognition" => { "face_count" => 1 },
        "ocr_analysis" => { "ocr_text" => "sunset in the city" }
      }
    )

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "This city shot is so clean.",
          "Love this vibe in the frame.",
          "The energy here is great."
        ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal "ollama", post.analysis["comment_generation_source"]
    assert_equal 3, Array(post.analysis["comment_suggestions"]).length
    assert_equal 1, generator.calls
    assert_equal "post", generator.last_kwargs[:channel]
    assert_kind_of Hash, generator.last_kwargs[:scored_context]
    assert_includes generator.last_kwargs[:scored_context].keys.map(&:to_sym), :prioritized_signals
    assert_equal "enabled", post.metadata.dig("comment_generation_policy", "status")
    assert_equal true, post.metadata.dig("comment_generation_policy", "history_ready")
  end

  it "generates comments when history is pending and visual context exists" do
    account, profile, post = build_account_profile_post
    post.update!(
      metadata: {
        "face_recognition" => { "face_count" => 1 },
        "ocr_analysis" => { "ocr_text" => "night skyline and traffic lights" }
      }
    )

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are not analyzed yet."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "Great city framing here.",
          "This shot has such a strong mood."
        ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal 1, generator.calls
    assert_equal "enabled_history_pending", post.metadata.dig("comment_generation_policy", "status")
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "history"
    assert_equal false, post.metadata.dig("comment_generation_policy", "history_ready")
  end

  it "keeps policy status focused on history readiness when evidence enforcement is disabled" do
    account, profile, post = build_account_profile_post

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are not analyzed yet."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "Trying this flow in manual mode.",
          "Looks clean even with partial history.",
          "Testing comment generation during bootstrap."
        ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator,
      enforce_required_evidence: false
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal 1, generator.calls
    assert_equal "enabled_history_pending", post.metadata.dig("comment_generation_policy", "status")
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "history"
    refute_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "face"
    refute_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "text_context"
  end

  it "accepts transcript-only text context when OCR is absent" do
    account, profile, post = build_account_profile_post
    post.update!(
      metadata: {
        "face_recognition" => { "face_count" => 1 },
        "video_processing" => {
          "semantic_route" => "image",
          "transcript" => "Sunset drive playlist on repeat."
        }
      }
    )

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "The vibe here is excellent.",
          "Love how this moment feels.",
          "Clean post and great energy."
        ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal true, post.metadata.dig("comment_generation_policy", "text_context_present")
    assert_equal false, post.metadata.dig("comment_generation_policy", "ocr_text_present")
    assert_equal true, post.metadata.dig("comment_generation_policy", "transcript_present")
    assert_equal 1, generator.calls
  end

  it "skips unsuitable reshared content and persists engagement classification" do
    account, profile, post = build_account_profile_post
    post.update!(
      caption: "Repost via @another_account quote of the day",
      metadata: { "is_repost" => true }
    )

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [ "Should not be used." ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal true, result[:blocked]
    assert_equal "blocked_unsuitable_for_engagement", post.analysis["comment_generation_status"]
    assert_equal 0, generator.calls
    assert_equal false, post.metadata.dig("engagement_classification", "engagement_suitable")
    assert_equal "quote", post.metadata.dig("engagement_classification", "content_type")
    assert_equal "unsuitable_for_engagement", post.metadata.dig("comment_generation_policy", "blocked_reason_code")
  end

  it "blocks low-relevance suggestions after scoring" do
    account, profile, post = build_account_profile_post
    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "Nice.",
          "Great.",
          "Cool."
        ]
      }
    )

    allow(Ai::CommentRelevanceScorer).to receive(:annotate_llm_order_with_breakdown).and_return(
      [
        { comment: "Nice.", score: 0.8, relevance_score: 0.8, llm_rank: 1, llm_order_bonus: 0.0, auto_post_eligible: false, confidence_level: "low", factors: {} },
        { comment: "Great.", score: 0.7, relevance_score: 0.7, llm_rank: 2, llm_order_bonus: 0.0, auto_post_eligible: false, confidence_level: "low", factors: {} }
      ]
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal true, result[:blocked]
    assert_equal "blocked_low_relevance", post.analysis["comment_generation_status"]
    assert_equal "low_relevance_suggestions", post.metadata.dig("comment_generation_policy", "blocked_reason_code")
    assert_equal 1, generator.calls
  end

  it "allows a single strong suggestion when high-score override is met" do
    account, profile, post = build_account_profile_post
    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "Love the candid energy in this frame.",
          "Nice."
        ]
      }
    )

    allow(Ai::CommentRelevanceScorer).to receive(:annotate_llm_order_with_breakdown).and_return(
      [
        { comment: "Love the candid energy in this frame.", score: 1.62, relevance_score: 1.58, llm_rank: 1, llm_order_bonus: 0.04, auto_post_eligible: true, confidence_level: "medium", factors: {} },
        { comment: "Nice.", score: 0.82, relevance_score: 0.82, llm_rank: 2, llm_order_bonus: 0.0, auto_post_eligible: false, confidence_level: "low", factors: {} }
      ]
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal false, result[:blocked]
    assert_equal "ok", post.analysis["comment_generation_status"]
    assert_equal [ "Love the candid energy in this frame." ], Array(post.analysis["comment_suggestions"])
    assert_equal true, post.metadata.dig("comment_generation_policy", "relevance", "high_score_override_applied")
  end

  it "blocks generation when visual context contains analysis failure markers" do
    account, profile, post = build_account_profile_post
    post.update!(
      analysis: {
        "image_description" => "No image or video content available for visual description.",
        "topics" => [ "unknown" ]
      }
    )

    prep = FakePreparationService.new(
      {
        "ready_for_comment_generation" => true,
        "reason_code" => "profile_context_ready",
        "reason" => "Profile context is ready."
      }
    )
    generator = FakeCommentGenerator.new(
      {
        status: "ok",
        source: "ollama",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [ "Should never be generated." ]
      }
    )

    result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      profile_preparation_service: prep,
      comment_generator: generator
    ).run!

    post.reload
    assert_equal true, result[:blocked]
    assert_equal "blocked_missing_required_evidence", post.analysis["comment_generation_status"]
    assert_equal "missing_visual_context", post.metadata.dig("comment_generation_policy", "blocked_reason_code")
    assert_equal 0, generator.calls
  end
end
