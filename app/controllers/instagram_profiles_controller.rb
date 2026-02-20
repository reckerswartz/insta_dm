class InstagramProfilesController < ApplicationController
  include ProfilePostPreviewSupport

  before_action :require_current_account!
  before_action :set_account_and_profile!, only: %i[
    show
    events
    tags
    captured_posts_section
    downloaded_stories_section
    messages_section
    action_history_section
    events_table_section
  ]

  def index
    @account = current_account

    query_result = InstagramProfiles::ProfilesIndexQuery.new(account: @account, params: params).call
    @q = query_result.q
    @filter = query_result.filter
    @page = query_result.page
    @per_page = query_result.per_page
    @total = query_result.total
    @pages = query_result.pages
    @profiles = query_result.profiles

    @latest_sync_run = @account.sync_runs.order(created_at: :desc).first
    @counts = {
      total: @account.instagram_profiles.count,
      mutuals: @account.instagram_profiles.where(following: true, follows_you: true).count,
      following: @account.instagram_profiles.where(following: true).count,
      followers: @account.instagram_profiles.where(follows_you: true).count
    }

    respond_to do |format|
      format.html
      format.json do
        render json: InstagramProfiles::TabulatorProfilesPayloadBuilder.new(
          profiles: @profiles,
          total: @total,
          pages: @pages,
          view_context: view_context
        ).call
      end
    end
  end

  def show
    snapshot = InstagramProfiles::ShowSnapshotService.new(account: @account, profile: @profile).call

    @profile_posts_total_count = snapshot[:profile_posts_total_count]
    @deleted_posts_count = snapshot[:deleted_posts_count]
    @active_posts_count = snapshot[:active_posts_count]
    @analyzed_posts_count = snapshot[:analyzed_posts_count]
    @pending_posts_count = snapshot[:pending_posts_count]
    @messages_count = snapshot[:messages_count]
    @action_logs_count = snapshot[:action_logs_count]
    @new_message = @profile.instagram_messages.new
    @latest_analysis = snapshot[:latest_analysis]
    @latest_story_intelligence_event = snapshot[:latest_story_intelligence_event]
    @available_tags = snapshot[:available_tags]
    @history_build_state = snapshot[:history_build_state]
    @history_ready = snapshot[:history_ready]
    @mutual_profiles = snapshot[:mutual_profiles]
  end

  def captured_posts_section
    profile_posts =
      @profile.instagram_profile_posts
        .includes(:instagram_profile_post_comments, :ai_analyses, { instagram_post_faces: :instagram_story_person }, media_attachment: :blob, preview_image_attachment: :blob)
        .recent_first
        .limit(40)

    render_profile_frame(
      frame_id: "profile_captured_posts_#{@profile.id}",
      partial: "instagram_profiles/captured_posts_section",
      locals: { profile: @profile, profile_posts: profile_posts }
    )
  end

  def downloaded_stories_section
    downloaded_story_events =
      @profile.instagram_profile_events
        .joins(:media_attachment)
        .with_attached_media
        .with_attached_preview_image
        .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
        .order(detected_at: :desc, id: :desc)
        .limit(18)

    render_profile_frame(
      frame_id: "profile_downloaded_stories_#{@profile.id}",
      partial: "instagram_profiles/downloaded_stories_section",
      locals: { profile: @profile, downloaded_story_events: downloaded_story_events }
    )
  end

  def messages_section
    messages = @profile.instagram_messages.recent_first.limit(120)
    render_profile_frame(
      frame_id: "profile_messages_#{@profile.id}",
      partial: "instagram_profiles/messages_section",
      locals: { messages: messages }
    )
  end

  def action_history_section
    action_logs = @profile.instagram_profile_action_logs.recent_first.limit(100)
    render_profile_frame(
      frame_id: "profile_actions_#{@profile.id}",
      partial: "instagram_profiles/action_history_section",
      locals: { action_logs: action_logs }
    )
  end

  def events_table_section
    render_profile_frame(
      frame_id: "profile_events_table_#{@profile.id}",
      partial: "instagram_profiles/events_table_section",
      locals: { profile: @profile }
    )
  end

  def events
    query_result = InstagramProfiles::EventsQuery.new(profile: @profile, params: params).call

    render json: InstagramProfiles::TabulatorEventsPayloadBuilder.new(
      events: query_result.events,
      total: query_result.total,
      pages: query_result.pages,
      view_context: view_context
    ).call
  end

  def tags
    names = Array(params[:tag_names]).map { |tag| tag.to_s.strip.downcase }.reject(&:blank?)
    custom = params[:custom_tags].to_s.split(/[,\n]/).map { |tag| tag.to_s.strip.downcase }.reject(&:blank?)
    desired = (names + custom).uniq

    tags = desired.map { |name| ProfileTag.find_or_create_by!(name: name) }

    @profile.profile_tags = tags
    @profile.save!

    respond_to do |format|
      format.html { redirect_to instagram_profile_path(@profile), notice: "Tags updated." }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: "Tags updated." }
          ),
          turbo_stream.replace(
            "profile_tags_section",
            partial: "instagram_profiles/profile_tags_section",
            locals: {
              profile: @profile,
              available_tags: InstagramProfiles::ShowSnapshotService::AVAILABLE_TAGS
            }
          )
        ]
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to instagram_profile_path(params[:id]), alert: "Unable to update tags: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to update tags: #{e.message}" }
        )
      end
    end
  end

  private

  def set_account_and_profile!
    @account = current_account
    @profile = @account.instagram_profiles.find(params[:id])
  end

  def render_profile_frame(frame_id:, partial:, locals:)
    body = render_to_string(partial: partial, locals: locals)
    if turbo_frame_request?
      render html: view_context.turbo_frame_tag(frame_id) { body.html_safe }
    else
      render html: body.html_safe
    end
  end
end
