require "rails_helper"

RSpec.describe Instagram::Client::ProfileStoryDatasetService do
  describe "#call" do
    it "raises when normalized username is blank" do
      service = described_class.new(
        fetch_profile_details: ->(username:) { { username: username } },
        fetch_web_profile_info: ->(_username) { {} },
        fetch_story_reel: ->(user_id:, referer_username:) { { user_id: user_id, referer_username: referer_username } },
        extract_story_item: ->(_item, username:, reel_owner_id:) { { username: username, owner_id: reel_owner_id } },
        normalize_username: ->(_value) { "" }
      )

      expect { service.call(username: "   ") }.to raise_error("Username cannot be blank")
    end

    it "returns profile metadata with normalized username and bounded stories list" do
      service = described_class.new(
        fetch_profile_details: ->(username:) { { username: username, source: "profile_details" } },
        fetch_web_profile_info: ->(_username) { { "data" => { "user" => { "id" => "123" } } } },
        fetch_story_reel: lambda { |user_id:, referer_username:|
          expect(user_id).to eq("123")
          expect(referer_username).to eq("target_user")
          { "items" => [1, 2, 3] }
        },
        extract_story_item: lambda { |item, username:, reel_owner_id:|
          { story_id: item, username: username, owner_id: reel_owner_id }
        },
        normalize_username: ->(value) { value.to_s.strip.downcase }
      )

      result = service.call(username: "  TARGET_USER  ", stories_limit: 2)

      expect(result[:profile]).to eq({ username: "target_user", source: "profile_details" })
      expect(result[:user_id]).to eq("123")
      expect(result[:stories]).to eq(
        [
          { story_id: 1, username: "target_user", owner_id: "123" },
          { story_id: 2, username: "target_user", owner_id: "123" }
        ]
      )
      expect(result[:fetched_at]).to be_a(Time)
    end
  end
end
