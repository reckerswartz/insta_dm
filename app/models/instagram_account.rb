class InstagramAccount < ApplicationRecord
  CONTINUOUS_PROCESSING_STATES = %w[idle running paused].freeze

  has_many :conversation_peers, dependent: :destroy
  has_many :instagram_profiles, dependent: :destroy
  has_many :instagram_messages, dependent: :destroy
  has_many :sync_runs, dependent: :destroy
  has_many :instagram_profile_analyses, through: :instagram_profiles
  has_many :instagram_posts, dependent: :destroy
  has_many :instagram_profile_posts, dependent: :destroy
  has_many :ai_analyses, dependent: :destroy
  has_many :ai_api_calls, dependent: :destroy
  has_many :instagram_profile_action_logs, dependent: :destroy
  has_many :instagram_profile_insights, dependent: :destroy
  has_many :instagram_profile_message_strategies, dependent: :destroy
  has_many :instagram_profile_signal_evidences, dependent: :destroy
  has_many :instagram_post_insights, dependent: :destroy
  has_many :instagram_post_entities, dependent: :destroy
  has_many :instagram_profile_history_chunks, dependent: :destroy
  has_many :instagram_stories, dependent: :destroy
  has_many :instagram_story_people, dependent: :destroy
  has_many :app_issues, dependent: :nullify
  has_many :active_storage_ingestions, dependent: :nullify

  encryption = Rails.application.config.active_record.encryption
  if encryption.primary_key.present? &&
     encryption.deterministic_key.present? &&
     encryption.key_derivation_salt.present?
    encrypts :cookies_json
    encrypts :local_storage_json
    encrypts :session_storage_json
    encrypts :auth_snapshot_json
  end

  validates :username, presence: true
  validates :continuous_processing_state, inclusion: { in: CONTINUOUS_PROCESSING_STATES }, allow_nil: true

  scope :continuous_processing_enabled, -> { where(continuous_processing_enabled: true) }

  def continuous_processing_backoff_active?
    continuous_processing_retry_after_at.present? && continuous_processing_retry_after_at > Time.current
  end

  def cookies
    return [] if cookies_json.blank?

    JSON.parse(cookies_json)
  rescue JSON::ParserError
    []
  end

  def cookies=(raw_cookies)
    self.cookies_json = Array(raw_cookies).to_json
  end

  def local_storage
    parse_json_array(local_storage_json)
  end

  def local_storage=(entries)
    self.local_storage_json = Array(entries).to_json
  end

  def session_storage
    parse_json_array(session_storage_json)
  end

  def session_storage=(entries)
    self.session_storage_json = Array(entries).to_json
  end

  def auth_snapshot
    return {} if auth_snapshot_json.blank?

    JSON.parse(auth_snapshot_json)
  rescue JSON::ParserError
    {}
  end

  def auth_snapshot=(value)
    self.auth_snapshot_json = value.to_h.to_json
  end

  def session_bundle
    {
      cookies: cookies,
      local_storage: local_storage,
      session_storage: session_storage,
      user_agent: user_agent,
      auth_snapshot: auth_snapshot
    }
  end

  def session_bundle=(bundle)
    payload = bundle.to_h.deep_symbolize_keys
    self.cookies = payload[:cookies]
    self.local_storage = payload[:local_storage]
    self.session_storage = payload[:session_storage]
    self.user_agent = payload[:user_agent].presence
    self.auth_snapshot = payload[:auth_snapshot] || {}
  end

  def sessionid_cookie_present?
    cookie_named_present?("sessionid")
  end

  def csrftoken_cookie_present?
    cookie_named_present?("csrftoken")
  end

  def cookie_authenticated?
    login_state.to_s == "authenticated" && sessionid_cookie_present?
  end

  private

  def parse_json_array(value)
    return [] if value.blank?

    JSON.parse(value)
  rescue JSON::ParserError
    []
  end

  def cookie_named_present?(name)
    target = name.to_s
    cookies.any? do |cookie|
      next false unless cookie.is_a?(Hash)

      cookie["name"].to_s == target && cookie["value"].to_s.present?
    end
  end
end
