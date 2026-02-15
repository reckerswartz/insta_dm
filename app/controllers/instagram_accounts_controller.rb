require "set"

class InstagramAccountsController < ApplicationController
  STORY_SYNC_LIMIT = SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT
  CONTINUOUS_STORY_SYNC_CYCLE_LIMIT = SyncAllHomeStoriesJob::MAX_CYCLES
  ACTIONS_TODO_POST_MAX_AGE_DAYS = 5

  before_action :set_account, only: %i[
    show update destroy select manual_login import_cookies export_cookies validate_session
    sync_next_profiles sync_profile_stories sync_stories_with_comments
    sync_all_stories_continuous story_media_archive generate_llm_comment technical_details
  ]

  def index
    @accounts = InstagramAccount.order(:id).to_a
    @metrics = Ops::Metrics.system
  end

  def show
    session[:instagram_account_id] = @account.id if session[:instagram_account_id].blank?

    @issues = Ops::AccountIssues.for(@account)
    @metrics = Ops::Metrics.for_account(@account)

    @latest_sync_run = @account.sync_runs.order(created_at: :desc).first
    @recent_failures =
      BackgroundJobFailure
        .where(instagram_account_id: @account.id)
        .order(occurred_at: :desc, id: :desc)
        .limit(25)
    @recent_audit_entries = Ops::AuditLogBuilder.for_account(instagram_account: @account, limit: 120)
    @actions_todo_posts = build_actions_todo_posts(account: @account, limit: 30)
    @skip_diagnostics = build_skip_diagnostics(account: @account, hours: 72)
  end

  def create
    username = params.dig(:instagram_account, :username).to_s.strip
    raise "Username cannot be blank" if username.blank?

    account = InstagramAccount.create!(username: username)
    session[:instagram_account_id] = account.id
    redirect_to instagram_account_path(account), notice: "Account added."
  rescue StandardError => e
    redirect_to instagram_accounts_path, alert: "Unable to add account: #{e.message}"
  end

  def update
    if @account.update(account_params)
      redirect_to instagram_account_path(@account), notice: "Account updated."
    else
      redirect_to instagram_account_path(@account), alert: @account.errors.full_messages.to_sentence
    end
  end

  def destroy
    @account.destroy!
    session[:instagram_account_id] = nil if session[:instagram_account_id].to_i == @account.id
    redirect_to instagram_accounts_path, notice: "Account removed."
  rescue StandardError => e
    redirect_to instagram_account_path(@account), alert: "Unable to remove account: #{e.message}"
  end

  def select
    session[:instagram_account_id] = @account.id
    redirect_to instagram_account_path(@account), notice: "Selected #{@account.username}."
  end

  def manual_login
    Instagram::Client.new(account: @account).manual_login!(timeout_seconds: timeout_seconds)
    @account.update!(login_state: "authenticated")

    redirect_to instagram_account_path(@account), notice: "Manual login completed and session bundle saved."
  rescue StandardError => e
    redirect_to instagram_account_path(@account), alert: "Manual login failed: #{e.message}"
  end

  def import_cookies
    payload = params[:cookies_json].to_s
    parsed = JSON.parse(payload)

    @account.cookies = parsed
    @account.login_state = "authenticated"
    @account.save!

    redirect_to instagram_account_path(@account), notice: "Cookies imported successfully."
  rescue JSON::ParserError
    redirect_to instagram_account_path(@account), alert: "Invalid JSON format for cookies."
  rescue StandardError => e
    redirect_to instagram_account_path(@account), alert: "Cookie import failed: #{e.message}"
  end

  def export_cookies
    send_data(
      JSON.pretty_generate(@account.cookies),
      filename: "instagram_cookies_#{@account.username}.json",
      type: "application/json"
    )
  end

  def validate_session
    client = Instagram::Client.new(account: @account)
    validation_result = client.validate_session!

    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: validation_result[:message] }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: validation_result[:valid] ? "notice" : "alert", message: validation_result[:message] }
        )
      end
      format.json { render json: validation_result }
    end
  rescue StandardError => e
    error_message = "Session validation failed: #{e.message}"
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: error_message }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: error_message }
        )
      end
      format.json { render json: { valid: false, message: error_message }, status: :unprocessable_entity }
    end
  end

  def sync_next_profiles
    limit = params.fetch(:limit, 10).to_i.clamp(1, 50)
    SyncNextProfilesForAccountJob.perform_later(instagram_account_id: @account.id, limit: limit)
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: "Queued sync for next #{limit} profiles." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Queued sync for next #{limit} profiles." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: "Unable to queue next-profile sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue next-profile sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_profile_stories
    story_limit = params.fetch(:story_limit, STORY_SYNC_LIMIT).to_i.clamp(1, STORY_SYNC_LIMIT)
    SyncHomeStoryCarouselJob.perform_later(
      instagram_account_id: @account.id,
      story_limit: story_limit,
      auto_reply_only: false
    )
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: "Queued next #{story_limit} stories." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Queued next #{story_limit} stories." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: "Unable to queue story sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue story sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_stories_with_comments
    story_limit = params.fetch(:story_limit, STORY_SYNC_LIMIT).to_i.clamp(1, STORY_SYNC_LIMIT)
    SyncHomeStoryCarouselJob.perform_later(
      instagram_account_id: @account.id,
      story_limit: story_limit,
      auto_reply_only: true
    )
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: "Queued next #{story_limit} stories (auto-reply tag required)." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Queued next #{story_limit} stories (auto-reply tag required)." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: "Unable to queue story sync with comments: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue story sync with comments: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_all_stories_continuous
    SyncAllHomeStoriesJob.perform_later(
      instagram_account_id: @account.id,
      cycle_story_limit: STORY_SYNC_LIMIT
    )
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: "Queued continuous story sync with auto-replies." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Queued continuous story sync with auto-replies." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: "Unable to queue continuous story sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue continuous story sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def story_media_archive
    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1

    per_page = params.fetch(:per_page, 24).to_i
    per_page = per_page.clamp(12, 80)

    on = parse_archive_date(params[:on])

    scope =
      InstagramProfileEvent
        .joins(:instagram_profile)
        .joins(:media_attachment)
        .with_attached_media
        .where(
          instagram_profiles: { instagram_account_id: @account.id },
          kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS
        )

    if on
      scope = scope.where("DATE(COALESCE(instagram_profile_events.occurred_at, instagram_profile_events.detected_at, instagram_profile_events.created_at)) = ?", on)
    end

    scope = scope.order(detected_at: :desc, id: :desc)
    total = scope.count
    events = scope.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: events.map { |event| archive_item_payload(event) },
      page: page,
      per_page: per_page,
      total: total,
      has_more: (page * per_page) < total,
      on: on&.iso8601
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def generate_llm_comment
    event_id = params.require(:event_id)
    provider = params.fetch(:provider, :ollama).to_sym
    model = params[:model].presence

    event = InstagramProfileEvent.find(event_id)
    
    # Ensure this event belongs to the current account and is a story archive item
    unless event.story_archive_item? && event.instagram_profile&.instagram_account_id == @account.id
      render json: { error: "Event not found or not accessible" }, status: :not_found
      return
    end

    # Generate the comment
    result = event.generate_llm_comment!(provider: provider, model: model)
    
    render json: {
      success: true,
      llm_generated_comment: event.llm_generated_comment,
      llm_comment_generated_at: event.llm_comment_generated_at,
      llm_comment_model: event.llm_comment_model,
      llm_comment_provider: event.llm_comment_provider,
      generation_result: result
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def technical_details
    event_id = params.require(:event_id)
    
    event = InstagramProfileEvent.find(event_id)
    
    # Ensure this event belongs to the current account
    unless event.instagram_profile&.instagram_account_id == @account.id
      render json: { error: "Event not found or not accessible" }, status: :not_found
      return
    end

    # Get technical details from metadata if available, or generate them
    technical_details = if event.llm_comment_metadata&.dig(:technical_details)
      event.llm_comment_metadata[:technical_details]
    else
      # Generate technical details on-demand if not stored
      context = event.send(:build_comment_context)
      event.send(:capture_technical_details, context)
    end

    render json: {
      event_id: event.id,
      has_llm_comment: event.has_llm_generated_comment?,
      llm_comment: event.llm_generated_comment,
      generated_at: event.llm_comment_generated_at,
      model: event.llm_comment_model,
      provider: event.llm_comment_provider,
      technical_details: technical_details
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_account
    @account = InstagramAccount.find(params[:id])
  end

  def account_params
    params.require(:instagram_account).permit(:username)
  end

  def timeout_seconds
    params.fetch(:timeout_seconds, 180).to_i.clamp(60, 900)
  end

  def parse_archive_date(raw)
    value = raw.to_s.strip
    return nil if value.blank?

    Date.iso8601(value)
  rescue StandardError
    nil
  end

  def archive_item_payload(event)
    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    blob = event.media.blob
    occurred_at = event.occurred_at || event.detected_at || event.created_at

    {
      id: event.id,
      profile_id: event.instagram_profile_id,
      profile_username: event.instagram_profile&.username.to_s,
      app_profile_url: event.instagram_profile_id ? instagram_profile_path(event.instagram_profile_id) : nil,
      instagram_profile_url: event.instagram_profile&.username.present? ? "https://www.instagram.com/#{event.instagram_profile.username}/" : nil,
      occurred_at: occurred_at&.iso8601,
      media_url: Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true),
      media_download_url: Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true, disposition: "attachment"),
      media_content_type: blob&.content_type.to_s.presence || metadata["media_content_type"].to_s,
      media_bytes: metadata["media_bytes"].to_i.positive? ? metadata["media_bytes"].to_i : blob&.byte_size.to_i,
      media_width: metadata["media_width"],
      media_height: metadata["media_height"],
      story_id: metadata["story_id"].to_s,
      story_url: metadata["story_url"].to_s.presence || metadata["permalink"].to_s.presence,
      reply_comment: metadata["reply_comment"].to_s.presence,
      skipped: ActiveModel::Type::Boolean.new.cast(metadata["skipped"]),
      skip_reason: metadata["skip_reason"].to_s.presence,
      # LLM comment fields
      llm_generated_comment: event.llm_generated_comment,
      llm_comment_generated_at: event.llm_comment_generated_at&.iso8601,
      llm_comment_model: event.llm_comment_model,
      llm_comment_provider: event.llm_comment_provider,
      llm_comment_metadata: event.llm_comment_metadata,
      has_llm_comment: event.has_llm_generated_comment?
    }
  end

  def build_actions_todo_posts(account:, limit:)
    cap = limit.to_i.clamp(1, 100)
    recent_cutoff = ACTIONS_TODO_POST_MAX_AGE_DAYS.days.ago
    candidates =
      account.instagram_profile_posts
        .includes(:instagram_profile, media_attachment: :blob)
        .where(ai_status: "analyzed")
        .where("taken_at >= ?", recent_cutoff)
        .limit(cap * 6)
        .to_a
    return [] if candidates.empty?

    sent_keys = commented_post_keys_for(account: account, profile_ids: candidates.map(&:instagram_profile_id).uniq)

    candidates.filter_map do |post|
      profile = post.instagram_profile
      next unless profile
      next if profile.last_active_at.present? && profile.last_active_at < recent_cutoff

      key = "#{post.instagram_profile_id}:#{post.shortcode}"
      next if sent_keys.include?(key)

      analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
      suggestions = Array(analysis["comment_suggestions"]).map { |v| v.to_s.strip }.reject(&:blank?).uniq.first(3)
      next if suggestions.empty?

      {
        post: post,
        profile: profile,
        suggestions: suggestions,
        profile_last_active_at: profile.last_active_at,
        post_taken_at: post.taken_at
      }
    end
      .sort_by do |item|
        [
          item[:profile_last_active_at] || Time.at(0),
          item[:post_taken_at] || Time.at(0)
        ]
      end
      .reverse
      .first(cap)
  end

  def commented_post_keys_for(account:, profile_ids:)
    return Set.new if profile_ids.blank?

    events =
      InstagramProfileEvent
        .joins(:instagram_profile)
        .where(instagram_profiles: { instagram_account_id: account.id, id: profile_ids })
        .where(kind: "post_comment_sent")
        .order(detected_at: :desc, id: :desc)
        .limit(2_000)

    Set.new(
      events.filter_map do |event|
        shortcode = event.metadata.is_a?(Hash) ? event.metadata["post_shortcode"].to_s.strip : ""
        next if shortcode.blank?

        "#{event.instagram_profile_id}:#{shortcode}"
      end
    )
  end

  def build_skip_diagnostics(account:, hours:)
    from_time = hours.to_i.hours.ago
    scope =
      InstagramProfileEvent
        .joins(:instagram_profile)
        .where(instagram_profiles: { instagram_account_id: account.id })
        .where(kind: %w[story_reply_skipped story_sync_failed story_ad_skipped])
        .where("detected_at >= ?", from_time)

    reason_rows = Hash.new(0)
    scope.limit(5_000).each do |event|
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      reason = metadata["reason"].to_s.presence || event.kind.to_s.presence || "unknown"
      reason_rows[reason] += 1
    end

    reasons = reason_rows.sort_by { |_reason, count| -count }.map do |reason, count|
      {
        reason: reason,
        count: count.to_i,
        classification: skip_reason_classification(reason)
      }
    end

    {
      window_hours: hours.to_i,
      total: scope.count,
      by_reason: reasons
    }
  rescue StandardError
    { window_hours: hours.to_i, total: 0, by_reason: [] }
  end

  def skip_reason_classification(reason)
    valid = %w[
      profile_not_in_network duplicate_story_already_replied invalid_story_media
      interaction_retry_window_active missing_auto_reply_tag external_profile_link_detected
    ]
    likely_improvable = %w[
      reply_box_not_found comment_submit_failed next_navigation_failed
      story_context_missing reply_precheck_error
    ]

    return "valid" if valid.include?(reason)
    return "review" if likely_improvable.include?(reason)
    return "valid" if reason.include?("ad") || reason.include?("sponsored")

    "review"
  end
end
