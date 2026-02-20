require "rails_helper"
require "securerandom"

RSpec.describe Ai::InsightSync do
  def create_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    [account, profile]
  end

  def create_post(account:, profile:)
    account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      status: "analyzed",
      author_username: profile.username,
      post_kind: "post"
    )
  end

  it "creates profile insight, strategy, and evidences from profile analysis payload" do
    account, profile = create_account_profile
    analysis_record = account.ai_analyses.create!(
      analyzable: profile,
      purpose: "profile",
      provider: "local",
      status: "succeeded",
      analysis: {}
    )

    analysis_hash = {
      "summary" => "Profile summary",
      "languages" => [
        { "language" => "english", "confidence" => "0.91", "evidence" => "bio" },
        { "language" => "spanish", "confidence" => "0.46", "evidence" => "comments" },
        { "language" => "", "confidence" => "0.10" }
      ],
      "writing_style" => {
        "tone" => "friendly",
        "formality" => "casual",
        "emoji_usage" => "high",
        "slang_level" => "medium"
      },
      "likes" => [ "coffee", "travel", "", nil ],
      "dislikes" => [ "spam" ],
      "suggested_dm_openers" => [ "Want to collab?" ],
      "suggested_comment_templates" => [ "Love this shot!" ],
      "personalization_tokens" => [ "travel", "photography" ],
      "no_go_zones" => [ "politics" ],
      "confidence_notes" => "Limited sample size."
    }

    described_class.sync_profile!(
      analysis_record: analysis_record,
      payload: { bio: "Official store for artisan goods", can_message: false },
      analysis_hash: analysis_hash
    )

    insight = InstagramProfileInsight.last
    expect(insight.instagram_profile_id).to eq(profile.id)
    expect(insight.primary_language).to eq("english")
    expect(insight.secondary_languages).to eq([ "spanish" ])
    expect(insight.engagement_style).to eq("friendly/casual/high")
    expect(insight.profile_type).to eq("business")
    expect(insight.messageability_score).to eq(0.2)

    strategy = insight.instagram_profile_message_strategy
    expect(strategy.cta_style).to eq("question_based")
    expect(strategy.opener_templates).to eq([ "Want to collab?" ])
    expect(strategy.comment_templates).to eq([ "Love this shot!" ])
    expect(strategy.dos).to include("coffee", "travel", "photography")
    expect(strategy.donts).to include("spam", "politics")

    evidences = insight.instagram_profile_signal_evidences
    expect(evidences.where(signal_type: "language").count).to eq(2)
    expect(evidences.where(signal_type: "interest").count).to eq(2)
    expect(evidences.where(signal_type: "avoidance").count).to eq(1)
    expect(evidences.where(signal_type: "confidence_note").count).to eq(1)
  end

  it "uses personal tag inference and default messaging values when optional fields are missing" do
    account, profile = create_account_profile
    profile.profile_tags << ProfileTag.find_or_create_by!(name: "personal_user")
    analysis_record = account.ai_analyses.create!(
      analyzable: profile,
      purpose: "profile",
      provider: "local",
      status: "succeeded",
      analysis: {}
    )

    described_class.sync_profile!(
      analysis_record: analysis_record,
      payload: { bio: "Official studio updates", can_message: nil },
      analysis_hash: {
        "summary" => "Minimal summary",
        "languages" => [],
        "likes" => [],
        "dislikes" => [],
        "suggested_dm_openers" => [ "Hello there" ]
      }
    )

    insight = InstagramProfileInsight.last
    expect(insight.profile_type).to eq("personal")
    expect(insight.engagement_style).to eq("unknown")
    expect(insight.messageability_score).to eq(0.5)

    strategy = insight.instagram_profile_message_strategy
    expect(strategy.cta_style).to eq("soft")
  end

  it "creates post insight and post entities for topics and personalization tokens" do
    account, profile = create_account_profile
    post = create_post(account: account, profile: profile)
    analysis_record = account.ai_analyses.create!(
      analyzable: post,
      purpose: "post",
      provider: "local",
      status: "succeeded",
      analysis: {}
    )

    described_class.sync_post!(
      analysis_record: analysis_record,
      analysis_hash: {
        "image_description" => "Runner on a city trail",
        "relevant" => "true",
        "author_type" => "creator",
        "sentiment" => "positive",
        "topics" => [ "fitness", "outdoors" ],
        "suggested_actions" => [ "comment", "save" ],
        "comment_suggestions" => [ "Great pace!" ],
        "confidence" => "0.66",
        "engagement_score" => nil,
        "evidence" => "Visible running gear",
        "recommended_next_action" => "",
        "personalization_tokens" => [ "marathon", "fitness" ]
      }
    )

    post_insight = InstagramPostInsight.last
    expect(post_insight.instagram_post_id).to eq(post.id)
    expect(post_insight.relevant).to eq(true)
    expect(post_insight.topics).to eq([ "fitness", "outdoors" ])
    expect(post_insight.suggested_actions).to eq([ "comment", "save" ])
    expect(post_insight.recommended_next_action).to eq("comment")
    expect(post_insight.engagement_score).to eq(0.66)

    entities_by_value = post_insight.instagram_post_entities.index_by(&:value)
    expect(entities_by_value.keys).to contain_exactly("fitness", "outdoors", "marathon")
    expect(entities_by_value.fetch("fitness").entity_type).to eq("topic")
    expect(entities_by_value.fetch("outdoors").entity_type).to eq("topic")
    expect(entities_by_value.fetch("marathon").entity_type).to eq("personalization_token")
  end

  it "no-ops when analysis target type does not match sync method" do
    account, profile = create_account_profile
    post = create_post(account: account, profile: profile)

    profile_analysis = account.ai_analyses.create!(
      analyzable: profile,
      purpose: "profile",
      provider: "local",
      status: "succeeded",
      analysis: {}
    )
    post_analysis = account.ai_analyses.create!(
      analyzable: post,
      purpose: "post",
      provider: "local",
      status: "succeeded",
      analysis: {}
    )

    expect do
      described_class.sync_profile!(analysis_record: post_analysis, payload: {}, analysis_hash: {})
    end.not_to change(InstagramProfileInsight, :count)

    expect do
      described_class.sync_post!(analysis_record: profile_analysis, analysis_hash: {})
    end.not_to change(InstagramPostInsight, :count)
  end
end
