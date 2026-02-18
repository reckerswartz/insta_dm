class Admin::StorageIngestionsController < Admin::BaseController
  def index
    scope = ActiveStorageIngestion.includes(:blob).recent_first
    scope = apply_tabulator_filters(scope)
    scope = apply_remote_sort(scope) || scope

    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1
    per_page = (params[:per_page].presence || params[:size].presence || 50).to_i.clamp(10, 200)

    total = scope.count
    pages = (total / per_page.to_f).ceil
    @ingestions = scope.offset((page - 1) * per_page).limit(per_page)

    respond_to do |format|
      format.html
      format.json { render json: tabulator_payload(ingestions: @ingestions, total: total, pages: pages) }
    end
  end

  private

  def apply_tabulator_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?

      case field
      when "attachment_name"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(attachment_name) LIKE ?", term)
      when "record_type"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(record_type, '')) LIKE ?", term)
      when "created_by_job_class"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(created_by_job_class, '')) LIKE ?", term)
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
    when "created_at"
      scope.order(Arel.sql("created_at #{dir}, id #{dir}"))
    when "blob_byte_size"
      scope.order(Arel.sql("blob_byte_size #{dir}, created_at DESC, id DESC"))
    when "record_type"
      scope.order(Arel.sql("record_type #{dir} NULLS LAST, created_at DESC, id DESC"))
    else
      nil
    end
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

  def tabulator_payload(ingestions:, total:, pages:)
    data = ingestions.map do |row|
      {
        id: row.id,
        created_at: row.created_at&.iso8601,
        attachment_name: row.attachment_name,
        record_type: row.record_type,
        record_id: row.record_id,
        blob_filename: row.blob_filename,
        blob_content_type: row.blob_content_type,
        blob_byte_size: row.blob_byte_size,
        created_by_job_class: row.created_by_job_class,
        created_by_active_job_id: row.created_by_active_job_id,
        queue_name: row.queue_name,
        instagram_account_id: row.instagram_account_id,
        instagram_profile_id: row.instagram_profile_id,
        blob_url: Rails.application.routes.url_helpers.rails_blob_path(row.blob, disposition: "attachment", only_path: true),
        record_url: record_url_for(row)
      }
    end

    { data: data, last_page: pages, last_row: total }
  end

  def record_url_for(row)
    case row.record_type
    when "InstagramAccount"
      Rails.application.routes.url_helpers.instagram_account_path(row.record_id)
    when "InstagramProfile"
      Rails.application.routes.url_helpers.instagram_profile_path(row.record_id)
    when "InstagramPost"
      Rails.application.routes.url_helpers.instagram_post_path(row.record_id)
    else
      nil
    end
  rescue StandardError
    nil
  end
end
