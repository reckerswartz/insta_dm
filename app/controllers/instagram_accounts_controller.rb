class InstagramAccountsController < ApplicationController
  STORY_SYNC_LIMIT = SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT
  CONTINUOUS_STORY_SYNC_CYCLE_LIMIT = SyncAllHomeStoriesJob::MAX_CYCLES
  STORY_ARCHIVE_SLOW_REQUEST_MS = Integer(ENV.fetch("STORY_ARCHIVE_SLOW_REQUEST_MS", "2000"))

  before_action :set_account, only: %i[
    show update destroy select manual_login import_cookies export_cookies validate_session
    sync_next_profiles sync_profile_stories sync_stories_with_comments
    sync_all_stories_continuous story_media_archive generate_llm_comment resend_story_reply technical_details
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

    snapshot = InstagramAccounts::DashboardSnapshotService.new(account: @account).call
    @issues = snapshot[:issues]
    @metrics = snapshot[:metrics]
    @latest_sync_run = snapshot[:latest_sync_run]
    @recent_failures = snapshot[:recent_failures]
    @recent_audit_entries = snapshot[:recent_audit_entries]
    @actions_todo_queue = snapshot[:actions_todo_queue]
    @skip_diagnostics = snapshot[:skip_diagnostics]
    @feed_capture_activity_entries = FeedCaptureActivityLog.entries_for(account: @account)
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
    clear_continuous_processing_auth_backoff!(account: @account)

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
    clear_continuous_processing_auth_backoff!(account: @account)

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
    if ActiveModel::Type::Boolean.new.cast(validation_result[:valid])
      @account.update!(login_state: "authenticated")
      clear_continuous_processing_auth_backoff!(account: @account)
    end

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
    result = InstagramAccounts::StoryArchiveQuery.new(
      account: @account,
      page: params.fetch(:page, 1),
      per_page: params.fetch(:per_page, 12),
      on: params[:on]
    ).call

    render json: {
      items: result.events.map { |event| InstagramAccounts::StoryArchiveItemSerializer.new(event: event).call },
      page: result.page,
      per_page: result.per_page,
      total: result.total,
      has_more: result.has_more,
      on: result.on&.iso8601
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def generate_llm_comment
    result = InstagramAccounts::LlmCommentRequestService.new(
      account: @account,
      event_id: params.require(:event_id),
      provider: params.fetch(:provider, :local),
      model: params[:model].presence,
      status_only: params[:status_only],
      force: params[:force],
      regenerate_all: params[:regenerate_all]
    ).call

    render json: result.payload, status: result.status
  end

  def resend_story_reply
    target_event = InstagramProfileEvent.includes(:instagram_profile).find_by(id: params.require(:event_id))
    unless target_event&.story_archive_item? && target_event.instagram_profile&.instagram_account_id == @account.id
      return render json: { error: "Event not found or not accessible", status: "failed" }, status: :not_found
    end

    job = SendStoryReplyEngagementJob.perform_later(
      instagram_account_id: @account.id,
      event_id: target_event.id,
      comment_text: params[:comment_text].to_s,
      requested_by: "manual_story_archive_send"
    )

    render json: {
      success: true,
      status: "queued",
      message: "Send action queued.",
      reason: "queued",
      event_id: target_event.id,
      job_id: job.job_id,
      queue_name: job.queue_name
    }, status: :accepted
  end

  def technical_details
    result = InstagramAccounts::TechnicalDetailsPayloadService.new(
      account: @account,
      event_id: params.require(:event_id)
    ).call

    render json: result.payload, status: result.status
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

  def clear_continuous_processing_auth_backoff!(account:)
    account.update!(
      continuous_processing_state: "idle",
      continuous_processing_retry_after_at: nil,
      continuous_processing_failure_count: 0,
      continuous_processing_last_error: nil
    )
  rescue StandardError
    nil
  end

end
