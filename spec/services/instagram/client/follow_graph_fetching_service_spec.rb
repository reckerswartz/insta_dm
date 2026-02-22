require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:client) { described_class.new(account: account) }
  let(:driver) { instance_double("Selenium::WebDriver::Driver") }

  before do
    client.define_singleton_method(:with_task_capture) do |driver:, task_name:, meta: {}, &blk|
      blk.call
    end
  end

  it "resumes follow list pagination from cache and persists the next cursor" do
    key = client.send(:follow_graph_cursor_cache_key, list_kind: :followers, profile_username: account.username)
    client.send(:follow_graph_cache_store).write(key, "cursor_old", expires_in: 1.hour)

    captured = {}
    client.define_singleton_method(:fetch_follow_list_via_api) do |profile_username:, list_kind:, driver: nil, starting_max_id: nil, page_limit: nil|
      captured = {
        profile_username: profile_username,
        list_kind: list_kind,
        driver: driver,
        starting_max_id: starting_max_id,
        page_limit: page_limit
      }

      {
        users: { "alpha" => { display_name: "Alpha" } },
        next_max_id: "cursor_new",
        complete: false,
        pages_fetched: 2,
        fetch_failed: false
      }
    end

    result = client.send(:collect_follow_list, driver, list_kind: :followers, profile_username: account.username)

    expect(result).to eq({ "alpha" => { display_name: "Alpha" } })
    expect(captured[:starting_max_id]).to eq("cursor_old")
    expect(captured[:page_limit]).to eq(Instagram::Client::FollowGraphFetchingService::FOLLOW_GRAPH_MAX_PAGES_PER_RUN)
    expect(client.send(:follow_graph_cache_store).read(key)).to eq("cursor_new")

    context = client.send(:follow_list_sync_context, :followers)
    expect(context[:starting_cursor]).to eq("cursor_old")
    expect(context[:next_cursor]).to eq("cursor_new")
    expect(context[:complete]).to eq(false)
    expect(context[:partial]).to eq(true)
  ensure
    client.send(:follow_graph_cache_store).delete(key)
  end

  it "clears cached cursor when a list completes" do
    key = client.send(:follow_graph_cursor_cache_key, list_kind: :following, profile_username: account.username)
    client.send(:follow_graph_cache_store).write(key, "cursor_old", expires_in: 1.hour)

    client.define_singleton_method(:fetch_follow_list_via_api) do |profile_username:, list_kind:, driver: nil, starting_max_id: nil, page_limit: nil|
      {
        users: { "beta" => { display_name: "Beta" } },
        next_max_id: nil,
        complete: true,
        pages_fetched: 1,
        fetch_failed: false
      }
    end

    result = client.send(:collect_follow_list, driver, list_kind: :following, profile_username: account.username)

    expect(result).to eq({ "beta" => { display_name: "Beta" } })
    expect(client.send(:follow_graph_cache_store).read(key)).to be_nil

    context = client.send(:follow_list_sync_context, :following)
    expect(context[:complete]).to eq(true)
    expect(context[:partial]).to eq(false)
  ensure
    client.send(:follow_graph_cache_store).delete(key)
  end
end
