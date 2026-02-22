require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client::SyncFollowGraphService do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }

  def upsert_callback_for(account)
    lambda do |users_hash, following_flag:, follows_you_flag:|
      users_hash.each do |username, attrs|
        profile = account.instagram_profiles.find_or_initialize_by(username: username)
        profile.display_name = attrs[:display_name].to_s.presence || profile.display_name
        profile.following = true if following_flag
        profile.follows_you = true if follows_you_flag
        profile.last_synced_at = Time.current
        profile.save!
      end
    end
  end

  def build_service(account:, followers:, following:, contexts:)
    described_class.new(
      account: account,
      with_recoverable_session: ->(label:, &blk) { blk.call },
      with_authenticated_driver: ->(&blk) { blk.call(Object.new) },
      collect_conversation_users: ->(_driver) { {} },
      collect_story_users: ->(_driver) { {} },
      collect_follow_list: lambda do |_driver, list_kind:, profile_username:|
        list_kind.to_sym == :followers ? followers : following
      end,
      upsert_follow_list: upsert_callback_for(account),
      follow_list_sync_context: ->(list_kind) { contexts[list_kind.to_sym] || {} }
    )
  end

  it "does not clear existing relationship flags when sync context is partial" do
    stale = account.instagram_profiles.create!(username: "stale_#{SecureRandom.hex(3)}", follows_you: true)
    kept = account.instagram_profiles.create!(username: "kept_#{SecureRandom.hex(3)}", follows_you: false)

    followers = { kept.username => { display_name: "Kept" } }
    following = {}
    contexts = {
      followers: { complete: false, starting_cursor: "cursor_1" },
      following: { complete: false, starting_cursor: "cursor_2" }
    }

    service = build_service(account: account, followers: followers, following: following, contexts: contexts)
    result = service.call

    expect(result[:followers_complete]).to eq(false)
    expect(result[:following_complete]).to eq(false)
    expect(stale.reload.follows_you).to eq(true)
    expect(kept.reload.follows_you).to eq(true)
  end

  it "reconciles stale flags only when a full snapshot is confirmed" do
    stale = account.instagram_profiles.create!(username: "stale_#{SecureRandom.hex(3)}", follows_you: true)
    kept = account.instagram_profiles.create!(username: "kept_#{SecureRandom.hex(3)}", follows_you: true)

    followers = { kept.username => { display_name: "Kept" } }
    following = {}
    contexts = {
      followers: { complete: true, starting_cursor: nil },
      following: { complete: false, starting_cursor: "cursor_2" }
    }

    service = build_service(account: account, followers: followers, following: following, contexts: contexts)
    result = service.call

    expect(result[:followers_complete]).to eq(true)
    expect(stale.reload.follows_you).to eq(false)
    expect(kept.reload.follows_you).to eq(true)
  end
end
