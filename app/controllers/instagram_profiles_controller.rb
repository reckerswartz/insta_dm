class InstagramProfilesController < ApplicationController
  before_action :require_current_account!

  def index
    @account = current_account

    scope = @account.instagram_profiles

    scope = apply_tabulator_profile_filters(scope)

    @q = params[:q].to_s.strip
    if @q.present?
      term = "%#{@q.downcase}%"
      scope = scope.where("LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?", term, term)
    end

    @filter = {
      mutual: truthy_param?(:mutual),
      following: truthy_param?(:following),
      follows_you: truthy_param?(:follows_you),
      can_message: truthy_param?(:can_message)
    }

    scope = scope.where(following: true, follows_you: true) if @filter[:mutual]
    scope = scope.where(following: true) if @filter[:following]
    scope = scope.where(follows_you: true) if @filter[:follows_you]
    scope = scope.where(can_message: true) if @filter[:can_message]

    scope = apply_remote_sort(scope) || apply_sort(scope, params[:sort].to_s)

    @page = params.fetch(:page, 1).to_i
    @page = 1 if @page < 1
    per_page_param = params[:per_page].presence || params[:size].presence
    @per_page = per_page_param.to_i
    @per_page = 50 if @per_page <= 0
    @per_page = @per_page.clamp(10, 200)

    @total = scope.count
    @pages = (@total / @per_page.to_f).ceil
    @profiles = scope.offset((@page - 1) * @per_page).limit(@per_page)

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
        render json: tabulator_payload(profiles: @profiles, total: @total, pages: @pages)
      end
    end
  end

  def show
    @account = current_account
    @profile = @account.instagram_profiles.find(params[:id])
    @messages = @profile.instagram_messages.recent_first.limit(200)
    @action_logs = @profile.instagram_profile_action_logs.recent_first.limit(100)
    @profile_posts = @profile.instagram_profile_posts.includes(:instagram_profile_post_comments, :ai_analyses, media_attachment: :blob).recent_first.limit(100)
    @new_message = @profile.instagram_messages.new
    @latest_analysis = @profile.latest_analysis
    @available_tags = %w[personal_user friend female_friend male_friend relative page excluded automatic_reply]
  end

  def events
    @account = current_account
    @profile = @account.instagram_profiles.find(params[:id])

    scope = @profile.instagram_profile_events
    scope = apply_tabulator_event_filters(scope)

    @q = params[:q].to_s.strip
    if @q.present?
      term = "%#{@q.downcase}%"
      scope = scope.where("LOWER(kind) LIKE ? OR LOWER(COALESCE(external_id, '')) LIKE ?", term, term)
    end

    scope = apply_events_remote_sort(scope) || scope.order(detected_at: :desc, id: :desc)

    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1

    per_page_param = params[:per_page].presence || params[:size].presence
    per_page = per_page_param.to_i
    per_page = 50 if per_page <= 0
    per_page = per_page.clamp(10, 200)

    total = scope.count
    pages = (total / per_page.to_f).ceil
    events = scope.offset((page - 1) * per_page).limit(per_page)

    render json: tabulator_events_payload(events: events, total: total, pages: pages)
  end

  def tags
    @account = current_account
    @profile = @account.instagram_profiles.find(params[:id])

    names = Array(params[:tag_names]).map { |t| t.to_s.strip.downcase }.reject(&:blank?)
    custom = params[:custom_tags].to_s.split(/[,\n]/).map { |t| t.to_s.strip.downcase }.reject(&:blank?)
    desired = (names + custom).uniq

    tags = desired.map { |n| ProfileTag.find_or_create_by!(name: n) }

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
              available_tags: %w[personal_user friend female_friend male_friend relative page excluded automatic_reply]
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

  def apply_tabulator_profile_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?

      case field
      when "username"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(username) LIKE ?", term)
      when "display_name"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(display_name, '')) LIKE ?", term)
      when "following"
        parsed = parse_tri_bool(value)
        scope = scope.where(following: parsed) unless parsed.nil?
      when "follows_you"
        parsed = parse_tri_bool(value)
        scope = scope.where(follows_you: parsed) unless parsed.nil?
      when "mutual"
        parsed = parse_tri_bool(value)
        if parsed == true
          scope = scope.where(following: true, follows_you: true)
        elsif parsed == false
          scope = scope.where.not(following: true, follows_you: true)
        end
      when "can_message"
        scope = if value.to_s == "unknown"
          scope.where(can_message: nil)
        else
          parsed = parse_tri_bool(value)
          parsed.nil? ? scope : scope.where(can_message: parsed)
        end
      end
    end
    scope
  end

  def apply_tabulator_event_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?
      next unless field == "kind"

      term = "%#{value.downcase}%"
      scope = scope.where("LOWER(kind) LIKE ?", term)
    end
    scope
  end

  def extract_tabulator_filters
    raw = params[:filters].presence || params[:filter]
    return [] unless raw.present?

    entries =
      case raw
      when String
        JSON.parse(raw)
      when Array
        raw
      when ActionController::Parameters
        raw.to_unsafe_h.values
      else
        []
      end

    Array(entries).filter_map do |item|
      h = item.respond_to?(:to_h) ? item.to_h : {}
      field = h["field"].to_s
      next if field.blank?

      { field: field, value: h["value"] }
    end
  rescue StandardError
    []
  end

  def parse_tri_bool(value)
    s = value.to_s
    return nil if s.blank?
    return true if %w[true 1 yes].include?(s.downcase)
    return false if %w[false 0 no].include?(s.downcase)

    nil
  end

  def truthy_param?(key)
    ActiveModel::Type::Boolean.new.cast(params[key])
  end

  def apply_sort(scope, sort)
    case sort
    when "username_asc"
      scope.order(Arel.sql("username ASC"))
    when "username_desc"
      scope.order(Arel.sql("username DESC"))
    when "recent_sync"
      scope.order(Arel.sql("last_synced_at DESC NULLS LAST, username ASC"))
    when "messageable"
      scope.order(Arel.sql("can_message DESC NULLS LAST, username ASC"))
    when "recent_active"
      scope.order(Arel.sql("last_active_at DESC NULLS LAST, username ASC"))
    else
      scope.order(Arel.sql("following DESC, follows_you DESC, username ASC"))
    end
  end

  def apply_remote_sort(scope)
    sorters = extract_tabulator_sorters
    return nil unless sorters.is_a?(Array)

    first = sorters.first
    return nil unless first.respond_to?(:[])

    field = first["field"].to_s
    dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

    case field
    when "username"
      scope.order(Arel.sql("username #{dir}"))
    when "display_name"
      scope.order(Arel.sql("display_name #{dir} NULLS LAST, username ASC"))
    when "following"
      scope.order(Arel.sql("following #{dir}, username ASC"))
    when "follows_you"
      scope.order(Arel.sql("follows_you #{dir}, username ASC"))
    when "mutual"
      scope.order(Arel.sql("following #{dir}, follows_you #{dir}, username ASC"))
    when "can_message"
      scope.order(Arel.sql("can_message #{dir} NULLS LAST, username ASC"))
    when "last_synced_at"
      scope.order(Arel.sql("last_synced_at #{dir} NULLS LAST, username ASC"))
    when "last_active_at"
      scope.order(Arel.sql("last_active_at #{dir} NULLS LAST, username ASC"))
    else
      nil
    end
  end

  def tabulator_payload(profiles:, total:, pages:)
    data = profiles.map do |p|
      {
        id: p.id,
        username: p.username,
        display_name: p.display_name,
        following: p.following,
        follows_you: p.follows_you,
        mutual: p.mutual?,
        can_message: p.can_message,
        restriction_reason: p.restriction_reason,
        last_synced_at: p.last_synced_at&.iso8601,
        last_active_at: p.last_active_at&.iso8601,
        avatar_url: avatar_url_for(p)
      }
    end

    {
      data: data,
      last_page: pages,
      last_row: total
    }
  end

  def avatar_url_for(profile)
    if profile.avatar.attached?
      Rails.application.routes.url_helpers.rails_blob_path(profile.avatar, only_path: true)
    elsif profile.profile_pic_url.present?
      profile.profile_pic_url
    else
      view_context.asset_path("default_avatar.svg")
    end
  end

  def apply_events_remote_sort(scope)
    sorters = extract_tabulator_sorters
    return nil unless sorters.is_a?(Array)

    first = sorters.first
    return nil unless first.respond_to?(:[])

    field = first["field"].to_s
    dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

    case field
    when "kind"
      scope.order(Arel.sql("kind #{dir}, detected_at DESC, id DESC"))
    when "occurred_at"
      scope.order(Arel.sql("occurred_at #{dir} NULLS LAST, detected_at DESC, id DESC"))
    when "detected_at"
      scope.order(Arel.sql("detected_at #{dir}, id #{dir}"))
    else
      nil
    end
  end

  def tabulator_events_payload(events:, total:, pages:)
    data = events.map do |e|
      {
        id: e.id,
        kind: e.kind,
        external_id: e.external_id,
        occurred_at: e.occurred_at&.iso8601,
        detected_at: e.detected_at&.iso8601,
        metadata_json: (e.metadata || {}).to_json,
        media_url: (e.media.attached? ? Rails.application.routes.url_helpers.rails_blob_path(e.media, only_path: true) : nil),
        media_download_url: (e.media.attached? ? Rails.application.routes.url_helpers.rails_blob_path(e.media, only_path: true, disposition: "attachment") : nil)
      }
    end

    {
      data: data,
      last_page: pages,
      last_row: total
    }
  end

  def extract_tabulator_sorters
    raw = params[:sorters].presence || params[:sort]
    return [] unless raw.present?

    case raw
    when String
      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed : []
    when Array
      raw
    when ActionController::Parameters
      raw.to_unsafe_h.values
    else
      []
    end
  rescue StandardError
    []
  end
end
