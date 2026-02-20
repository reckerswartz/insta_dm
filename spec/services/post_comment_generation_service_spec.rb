require "rails_helper"
require "securerandom"

RSpec.describe Ai::PostCommentGenerationService do
  class FakePreparationService
    def initialize(payload)
      @payload = payload
    end

    def prepare!(force: false)
      @payload
    end
  end

  class FakeCommentGenerator
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = 0
    end

    def generate!(**_kwargs)
      @calls += 1
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
      analysis: {
        "image_description" => "A person in a city street.",
        "topics" => [ "person", "city" ]
      },
      metadata: {}
    )

    [ account, profile, post ]
  end

  it "blocks comment generation when required face/text evidence is missing" do
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
    assert_equal "blocked_missing_required_evidence", post.analysis["comment_generation_status"]
    assert_equal [], Array(post.analysis["comment_suggestions"])
    assert_equal 0, generator.calls
    assert_equal "blocked", post.metadata.dig("comment_generation_policy", "status")
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "history"
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "face"
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "text_context"
  end

  it "generates comments when required history/face/ocr evidence is present" do
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
    assert_equal "enabled", post.metadata.dig("comment_generation_policy", "status")
    assert_equal true, post.metadata.dig("comment_generation_policy", "history_ready")
  end

  it "generates comments when history is pending but required content signals are present" do
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

  it "allows generation with missing evidence when policy enforcement is disabled" do
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
    assert_equal "enabled_with_missing_required_evidence", post.metadata.dig("comment_generation_policy", "status")
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "history"
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "face"
    assert_includes Array(post.metadata.dig("comment_generation_policy", "missing_signals")), "text_context"
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
end
