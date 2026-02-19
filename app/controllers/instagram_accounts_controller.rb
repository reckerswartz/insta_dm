require "set"

class InstagramAccountsController < ApplicationController
  STORY_SYNC_LIMIT = SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT
  CONTINUOUS_STORY_SYNC_CYCLE_LIMIT = SyncAllHomeStoriesJob::MAX_CYCLES
  ACTIONS_TODO_POST_MAX_AGE_DAYS = 5
  STORY_ARCHIVE_SLOW_REQUEST_MS = Integer(ENV.fetch("STORY_ARCHIVE_SLOW_REQUEST_MS", "2000"))
  STORY_ARCHIVE_PREVIEW_ENQUEUE_TTL_SECONDS = Integer(ENV.fetch("STORY_ARCHIVE_PREVIEW_ENQUEUE_TTL_SECONDS", "900"))

  before_action :set_account, only: %i[
    show update destroy select manual_login import_cookies export_cookies validate_session
    sync_next_profiles sync_profile_stories sync_stories_with_comments
    sync_all_stories_continuous story_media_archive generate_llm_comment technical_details
    run_continuous_processing
  ]
  before_action :normalize_navigation_format, only: %i[show]
  around_action :log_story_media_archive_request, only: %i[story_media_archive]

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
    redirect_to instagram_account_path(@account), notice: "Selected #{@account.username}.", status: :see_other
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

  def run_continuous_processing
    trigger_source = params[:trigger_source].to_s.presence || "manual_account_trigger"

    ProcessInstagramAccountContinuouslyJob.perform_later(
      instagram_account_id: @account.id,
      trigger_source: trigger_source
    )

    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), notice: "Queued continuous processing pipeline." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Queued continuous processing pipeline." }
        )
      end
      format.json { render json: { status: "queued" }, status: :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_account_path(@account), alert: "Unable to queue continuous processing: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue continuous processing: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def story_media_archive
    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1

    per_page = params.fetch(:per_page, 12).to_i
    per_page = per_page.clamp(8, 40)

    on = parse_archive_date(params[:on])

    scope =
      InstagramProfileEvent
        .joins(:instagram_profile)
        .joins(:media_attachment)
        .includes(:instagram_profile)
        .with_attached_media
        .with_attached_preview_image
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
    provider = params.fetch(:provider, :local).to_s
    model = params[:model].presence
    status_only = ActiveModel::Type::Boolean.new.cast(params[:status_only])

    event = InstagramProfileEvent.find(event_id)
    
    # Ensure this event belongs to the current account and is a story archive item
    unless event.story_archive_item? && event.instagram_profile&.instagram_account_id == @account.id
      render json: { error: "Event not found or not accessible" }, status: :not_found
      return
    end

    if event.has_llm_generated_comment?
      event.update_column(:llm_comment_status, "completed") if event.llm_comment_status.to_s != "completed"

      render json: {
        success: true,
        status: "completed",
        event_id: event.id,
        llm_generated_comment: event.llm_generated_comment,
        llm_comment_generated_at: event.llm_comment_generated_at,
        llm_comment_model: event.llm_comment_model,
        llm_comment_provider: event.llm_comment_provider,
        llm_comment_relevance_score: event.llm_comment_relevance_score
      }
      return
    end

    if event.llm_comment_in_progress?
      if stale_llm_comment_job?(event)
        event.update_columns(
          llm_comment_status: "failed",
          llm_comment_last_error: "Previous generation job appears stalled. Please retry.",
          updated_at: Time.current
        )
      else
      render json: {
        success: true,
        status: event.llm_comment_status,
        event_id: event.id,
        job_id: event.llm_comment_job_id,
        estimated_seconds: llm_comment_estimated_seconds(event: event),
        queue_size: ai_queue_size
      }, status: :accepted
      return
      end
    end

    if status_only
      render json: {
        success: true,
        status: event.llm_comment_status.presence || "not_requested",
        event_id: event.id,
        estimated_seconds: llm_comment_estimated_seconds(event: event),
        queue_size: ai_queue_size
      }
      return
    end

    job = GenerateLlmCommentJob.perform_later(
      instagram_profile_event_id: event.id,
      provider: provider,
      model: model,
      requested_by: "dashboard_manual_request"
    )
    event.queue_llm_comment_generation!(job_id: job.job_id)

    render json: {
      success: true,
      status: "queued",
      event_id: event.id,
      job_id: job.job_id,
      estimated_seconds: llm_comment_estimated_seconds(event: event, include_queue: true),
      queue_size: ai_queue_size
    }, status: :accepted
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
    llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
    stored_details = llm_meta["technical_details"] || llm_meta[:technical_details]
    technical_details = hydrate_technical_details(event: event, technical_details: stored_details)

    render json: {
      event_id: event.id,
      has_llm_comment: event.has_llm_generated_comment?,
      llm_comment: event.llm_generated_comment,
      generated_at: event.llm_comment_generated_at,
      model: event.llm_comment_model,
      provider: event.llm_comment_provider,
      status: event.llm_comment_status,
      relevance_score: event.llm_comment_relevance_score,
      last_error: event.llm_comment_last_error,
      timeline: story_timeline_for(event: event),
      technical_details: technical_details
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def hydrate_technical_details(event:, technical_details:)
    current = technical_details.is_a?(Hash) ? technical_details.deep_stringify_keys : {}
    has_required_sections =
      current["local_story_intelligence"].is_a?(Hash) &&
      current["analysis"].is_a?(Hash) &&
      current["prompt_engineering"].is_a?(Hash)

    return current if has_required_sections

    context = event.send(:build_comment_context)
    generated = event.send(:capture_technical_details, context)
    generated_hash = generated.is_a?(Hash) ? generated.deep_stringify_keys : {}
    generated_hash.deep_merge(current)
  rescue StandardError
    current
  end

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
    llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
    ownership_data =
      if llm_meta["ownership_classification"].is_a?(Hash)
        llm_meta["ownership_classification"]
      elsif metadata["story_ownership_classification"].is_a?(Hash)
        metadata["story_ownership_classification"]
      elsif metadata.dig("validated_story_insights", "ownership_classification").is_a?(Hash)
        metadata.dig("validated_story_insights", "ownership_classification")
      else
        {}
      end
    blob = event.media.blob
    profile = event.instagram_profile
    story_posted_at = metadata["upload_time"].presence || metadata["taken_at"].presence
    downloaded_at = metadata["downloaded_at"].presence || event.occurred_at&.iso8601
    avatar_url =
      if profile&.avatar&.attached?
        Rails.application.routes.url_helpers.rails_blob_path(profile.avatar, only_path: true)
      else
        profile&.profile_pic_url.to_s.presence
      end
    video_static_frame_only = static_video_preview?(metadata: metadata)
    media_preview_image_url = preferred_video_preview_image_url(event: event, metadata: metadata)

    {
      id: event.id,
      profile_id: event.instagram_profile_id,
      profile_username: profile&.username.to_s,
      profile_display_name: profile&.display_name.to_s.presence || profile&.username.to_s,
      profile_avatar_url: avatar_url,
      app_profile_url: event.instagram_profile_id ? instagram_profile_path(event.instagram_profile_id) : nil,
      instagram_profile_url: profile&.username.present? ? "https://www.instagram.com/#{profile.username}/" : nil,
      story_posted_at: story_posted_at,
      downloaded_at: downloaded_at,
      media_url: Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true),
      media_download_url: Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true, disposition: "attachment"),
      media_content_type: blob&.content_type.to_s.presence || metadata["media_content_type"].to_s,
      media_preview_image_url: media_preview_image_url,
      video_static_frame_only: video_static_frame_only,
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
      llm_comment_status: event.llm_comment_status,
      llm_comment_attempts: event.llm_comment_attempts,
      llm_comment_last_error: event.llm_comment_last_error,
      llm_comment_last_error_preview: text_preview(event.llm_comment_last_error, max: 180),
      llm_comment_relevance_score: event.llm_comment_relevance_score,
      llm_generated_comment_preview: text_preview(event.llm_generated_comment, max: 260),
      has_llm_comment: event.has_llm_generated_comment?,
      story_ownership_label: ownership_data["label"].to_s.presence,
      story_ownership_summary: ownership_data["summary"].to_s.presence,
      story_ownership_confidence: ownership_data["confidence"]
    }
  end

  def static_video_preview?(metadata:)
    data = metadata.is_a?(Hash) ? metadata : {}
    processing = data["processing_metadata"].is_a?(Hash) ? data["processing_metadata"] : {}
    frame_change = processing["frame_change_detection"].is_a?(Hash) ? processing["frame_change_detection"] : {}
    local_intel = data["local_story_intelligence"].is_a?(Hash) ? data["local_story_intelligence"] : {}

    processing["source"].to_s == "video_static_single_frame" ||
      frame_change["processing_mode"].to_s == "static_image" ||
      local_intel["video_processing_mode"].to_s == "static_image"
  end

  def preferred_video_preview_image_url(event:, metadata:)
    if event.preview_image.attached?
      return Rails.application.routes.url_helpers.rails_blob_path(event.preview_image, only_path: true)
    end

    data = metadata.is_a?(Hash) ? metadata : {}
    direct = data["image_url"].to_s.presence
    return direct if direct.present?

    variants = Array(data["carousel_media"])
    candidate = variants.find { |entry| entry.is_a?(Hash) && entry["image_url"].to_s.present? }
    variant_url = candidate.is_a?(Hash) ? candidate["image_url"].to_s.presence : nil
    return variant_url if variant_url.present?

    local_video_preview_representation_url(event: event)
  end

  def local_video_preview_representation_url(event:)
    return nil unless event.media.attached?
    return nil unless event.media.blob&.content_type.to_s.start_with?("video/")

    enqueue_story_preview_generation(event: event)
    nil
  rescue StandardError
    nil
  end

  def enqueue_story_preview_generation(event:)
    return if event.preview_image.attached?

    cache_key = "story_archive:preview_enqueue:#{event.id}"
    Rails.cache.fetch(cache_key, expires_in: STORY_ARCHIVE_PREVIEW_ENQUEUE_TTL_SECONDS.seconds) do
      GenerateStoryPreviewImageJob.perform_later(instagram_profile_event_id: event.id)
      true
    end
  rescue StandardError => e
    Rails.logger.warn("[story_media_archive] preview enqueue failed event_id=#{event.id}: #{e.class}: #{e.message}")
  end

  def log_story_media_archive_request
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(1)
    return if elapsed_ms < STORY_ARCHIVE_SLOW_REQUEST_MS

    pool_stats = ActiveRecord::Base.connection_pool.stat rescue {}
    Rails.logger.warn(
      "[story_media_archive] slow request " \
      "account_id=#{@account&.id} elapsed_ms=#{elapsed_ms} " \
      "pool_size=#{pool_stats[:size]} pool_busy=#{pool_stats[:busy]} " \
      "pool_waiting=#{pool_stats[:waiting]}"
    )
  end

  def normalize_navigation_format
    request.format = :html if request.format.turbo_stream?
  end

  def text_preview(raw, max:)
    text = raw.to_s
    return text if text.length <= max

    "#{text[0, max]}..."
  end

  def story_timeline_for(event:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    story = event.instagram_stories.order(taken_at: :desc, id: :desc).first

    posted_at = metadata["upload_time"].presence || metadata["taken_at"].presence || story&.taken_at&.iso8601
    downloaded_at = metadata["downloaded_at"].presence || event.occurred_at&.iso8601 || event.created_at&.iso8601
    detected_at = event.detected_at&.iso8601

    {
      story_posted_at: posted_at,
      downloaded_to_system_at: downloaded_at,
      event_detected_at: detected_at
    }
  end

  def llm_comment_estimated_seconds(event:, include_queue: false)
    base = 18
    queue_factor = include_queue ? (ai_queue_size * 4) : 0
    attempt_factor = event.llm_comment_attempts.to_i * 6
    preprocess_factor = story_local_context_preprocess_penalty(event: event)
    (base + queue_factor + attempt_factor + preprocess_factor).clamp(10, 240)
  end

  def story_local_context_preprocess_penalty(event:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    has_context = metadata["local_story_intelligence"].is_a?(Hash) ||
      metadata["ocr_text"].to_s.present? ||
      Array(metadata["content_signals"]).any?

    return 0 if has_context

    media_type = event.media&.blob&.content_type.to_s.presence || metadata["media_content_type"].to_s
    media_type.start_with?("image/") ? 16 : 8
  rescue StandardError
    0
  end

  def ai_queue_size
    return 0 unless Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"

    require "sidekiq/api"
    Sidekiq::Queue.new("ai").size.to_i
  rescue StandardError
    0
  end

  def stale_llm_comment_job?(event)
    return false unless event.llm_comment_in_progress?
    return false if event.updated_at && event.updated_at > 5.minutes.ago
    return false unless Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"

    require "sidekiq/api"
    job_id = event.llm_comment_job_id.to_s
    event_marker = "instagram_profile_event_id\"=>#{event.id}"

    busy = Sidekiq::Workers.new.any? do |_pid, _tid, work|
      payload = work["payload"].to_s
      payload.include?(job_id) || payload.include?(event_marker)
    end
    return false if busy

    queued = Sidekiq::Queue.new("ai").any? do |job|
      payload = job.item.to_s
      payload.include?(job_id) || payload.include?(event_marker)
    end
    return false if queued

    retrying = Sidekiq::RetrySet.new.any? do |job|
      payload = job.item.to_s
      payload.include?(job_id) || payload.include?(event_marker)
    end
    return false if retrying

    scheduled = Sidekiq::ScheduledSet.new.any? do |job|
      payload = job.item.to_s
      payload.include?(job_id) || payload.include?(event_marker)
    end
    return false if scheduled

    true
  rescue StandardError
    false
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
