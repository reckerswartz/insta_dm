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

    def story_reply_eligibility(username:, story_id:)
      uname = normalize_username(username)
      sid = normalize_story_id_token(story_id)
      return { eligible: false, reason_code: "missing_story_username", status: "failed", story_item: nil } if uname.blank?
      return { eligible: false, reason_code: "missing_story_id", status: "failed", story_item: nil } if sid.blank?

      item = resolve_story_item_via_api(username: uname, story_id: sid, cache: {})
      unless item.is_a?(Hash)
        return {
          eligible: true,
          reason_code: "story_lookup_unresolved",
          status: "unknown",
          availability_known: false,
          story_item: nil
        }
      end

      if item[:can_reply] == false
        return {
          eligible: false,
          reason_code: "commenting_not_allowed",
          status: "failed",
          availability_known: true,
          story_item: item
        }
      end

      if item[:can_reply].nil?
        return {
          eligible: true,
          reason_code: "api_can_reply_missing",
          status: "unknown",
          availability_known: true,
          story_item: item
        }
      end

      { eligible: true, reason_code: nil, status: "eligible", availability_known: true, story_item: item }
    rescue StandardError => e
      {
        eligible: true,
        reason_code: "eligibility_check_error:#{e.class.name}",
        status: "unknown",
        availability_known: false,
        story_item: nil
      }
    end

    def send_story_reply_via_api!(story_id:, story_username:, comment_text:)
      result = comment_on_story_via_api!(
        story_id: story_id,
        story_username: story_username,
        comment_text: comment_text
      )
      result.is_a?(Hash) ? result : { posted: false, method: "api", reason: "invalid_api_result" }
    rescue StandardError => e
      { posted: false, method: "api", reason: "api_exception:#{e.class.name}" }
    end
  end
end
