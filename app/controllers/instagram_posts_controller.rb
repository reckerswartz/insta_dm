class InstagramPostsController < ApplicationController
  before_action :require_current_account!

  def index
    @account = current_account

    scope = @account.instagram_posts
    scope = apply_tabulator_filters(scope)

    @q = params[:q].to_s.strip
    if @q.present?
      term = "%#{@q.downcase}%"
      scope = scope.where("LOWER(shortcode) LIKE ? OR LOWER(COALESCE(author_username,'')) LIKE ?", term, term)
    end

    if params[:status].present?
      scope = scope.where(status: params[:status].to_s)
    end

    scope = apply_remote_sort(scope) || scope.order(detected_at: :desc, id: :desc)

    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1
    per_page_param = params[:per_page].presence || params[:size].presence
    per_page = per_page_param.to_i
    per_page = 50 if per_page <= 0
    per_page = per_page.clamp(10, 200)

    total = scope.count
    pages = (total / per_page.to_f).ceil
    posts = scope.offset((page - 1) * per_page).limit(per_page)

    respond_to do |format|
      format.html
      format.json do
        render json: tabulator_payload(posts: posts, total: total, pages: pages)
      end
    end
  end

  def show
    @account = current_account
    @post = @account.instagram_posts.find(params[:id])
    @latest_analysis = @post.ai_analyses.where(purpose: "post").recent_first.first
  end

  private

  def apply_tabulator_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?

      case field
      when "author_username"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(author_username,'')) LIKE ?", term)
      when "status"
        scope = scope.where(status: value.to_s)
      when "post_kind"
        scope = scope.where(post_kind: value.to_s)
      end
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

  def apply_remote_sort(scope)
    sorters = extract_tabulator_sorters
    return nil unless sorters.is_a?(Array)

    first = sorters.first
    return nil unless first.respond_to?(:[])

    field = first["field"].to_s
    dir = first["dir"].to_s.downcase == "desc" ? "DESC" : "ASC"

    case field
    when "detected_at"
      scope.order(Arel.sql("detected_at #{dir}, id #{dir}"))
    when "author_username"
      scope.order(Arel.sql("author_username #{dir} NULLS LAST, detected_at DESC, id DESC"))
    when "status"
      scope.order(Arel.sql("status #{dir}, detected_at DESC, id DESC"))
    else
      nil
    end
  end

  def tabulator_payload(posts:, total:, pages:)
    data = posts.map do |p|
      {
        id: p.id,
        shortcode: p.shortcode,
        post_kind: p.post_kind,
        author_username: p.author_username,
        detected_at: p.detected_at&.iso8601,
        status: p.status,
        relevant: p.analysis.is_a?(Hash) ? p.analysis["relevant"] : nil,
        author_type: p.analysis.is_a?(Hash) ? p.analysis["author_type"] : nil,
        permalink: p.permalink,
        media_attached: p.media.attached?,
        open_url: Rails.application.routes.url_helpers.instagram_post_path(p)
      }
    end

    { data: data, last_page: pages, last_row: total }
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
