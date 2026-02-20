require "selenium-webdriver"
require "fileutils"
require "time"
require "net/http"
require "json"
require "cgi"
require "base64"
require "digest"
require "stringio"
require "set"

module Instagram
  class Client
    include StoryScraperService
    include FeedEngagementService
    include BrowserAutomation
    include DirectMessagingService
    include CommentPostingService
    include FollowGraphFetchingService
    include ProfileFetchingService
    include FeedFetchingService
    include SyncCollectionSupport
    include StoryApiSupport
    include CoreHelpers
    include TaskCaptureSupport
    include SessionRecoverySupport
    include AutoEngagementSupport
    include StoryNavigationSupport
    include MediaDownloadSupport
    include StoryInteractionSupport
    include StorySignalSupport
    include BrowserStateSupport

    INSTAGRAM_BASE_URL = "https://www.instagram.com".freeze
    DEBUG_CAPTURE_DIR = Rails.root.join("log", "instagram_debug").freeze
    STORY_INTERACTION_RETRY_DAYS = 3
    PROFILE_FEED_PAGE_SIZE = 30
    PROFILE_FEED_MAX_PAGES = 120
    PROFILE_FEED_BROWSER_ITEM_CAP = 500

    def initialize(account:)
      @account = account
    end

    def manual_login!(timeout_seconds: 180)
      with_driver(headless: false) do |driver|
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/accounts/login/")
        wait_for_manual_login!(driver: driver, timeout_seconds: timeout_seconds)

        persist_session_bundle!(driver)
        @account.login_state = "authenticated"
        @account.save!
      end
    end

    def validate_session!
      SessionValidationService.new(
        account: @account,
        with_driver: method(:with_driver),
        wait_for: method(:wait_for),
        logger: defined?(Rails) ? Rails.logger : nil
      ).call
    end

    def fetch_profile_analysis_dataset!(username:, posts_limit: nil, comments_limit: 8)
      ProfileAnalysisDatasetService.new(
        fetch_profile_details: method(:fetch_profile_details!),
        fetch_web_profile_info: method(:fetch_web_profile_info),
        fetch_profile_feed_items_for_analysis: method(:fetch_profile_feed_items_for_analysis),
        extract_post_for_analysis: method(:extract_post_for_analysis),
        enrich_missing_post_comments_via_browser: method(:enrich_missing_post_comments_via_browser!),
        normalize_username: method(:normalize_username)
      ).call(username: username, posts_limit: posts_limit, comments_limit: comments_limit)
    end

    def fetch_profile_story_dataset!(username:, stories_limit: 20)
      ProfileStoryDatasetService.new(
        fetch_profile_details: method(:fetch_profile_details!),
        fetch_web_profile_info: method(:fetch_web_profile_info),
        fetch_story_reel: method(:fetch_story_reel),
        extract_story_item: method(:extract_story_item),
        normalize_username: method(:normalize_username)
      ).call(username: username, stories_limit: stories_limit)
    end
  end
end
