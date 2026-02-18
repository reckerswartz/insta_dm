class Admin::IssuesController < Admin::BaseController
  def index
    scope = AppIssue.includes(:background_job_failure).recent_first
    scope = apply_tabulator_filters(scope)

    q = params[:q].to_s.strip
    if q.present?
      term = "%#{q.downcase}%"
      scope = scope.where(
        "LOWER(title) LIKE ? OR LOWER(COALESCE(details, '')) LIKE ? OR LOWER(issue_type) LIKE ? OR LOWER(source) LIKE ?",
        term, term, term, term
      )
    end

    scope = apply_remote_sort(scope) || scope

    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1
    per_page = (params[:per_page].presence || params[:size].presence || 50).to_i.clamp(10, 200)

    total = scope.count
    pages = (total / per_page.to_f).ceil
    @issues = scope.offset((page - 1) * per_page).limit(per_page)

    respond_to do |format|
      format.html
      format.json { render json: tabulator_payload(issues: @issues, total: total, pages: pages) }
    end
  end

  def update
    issue = AppIssue.find(params[:id])
    status = params[:status].to_s
    notes = params[:resolution_notes].to_s

    case status
    when "open"
      issue.mark_open!(notes: notes)
    when "pending"
      issue.mark_pending!(notes: notes)
    when "resolved"
      issue.mark_resolved!(notes: notes)
    else
      raise ArgumentError, "Unsupported status: #{status}"
    end

    respond_to do |format|
      format.html { redirect_to admin_issues_path, notice: "Issue ##{issue.id} updated." }
      format.json { render json: { ok: true, id: issue.id, status: issue.status } }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to admin_issues_path, alert: "Unable to update issue: #{e.message}" }
      format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def retry_job
    issue = AppIssue.find(params[:id])
    failure = issue.background_job_failure
    raise Jobs::FailureRetry::RetryError, "Issue is not linked to a failed background job" unless failure

    Jobs::FailureRetry.enqueue!(failure)
    issue.mark_pending!(notes: "Retry queued at #{Time.current.iso8601}.")

    respond_to do |format|
      format.html { redirect_to admin_issues_path, notice: "Retry queued for issue ##{issue.id}." }
      format.json { render json: { ok: true } }
    end
  rescue Jobs::FailureRetry::RetryError => e
    respond_to do |format|
      format.html { redirect_to admin_issues_path, alert: e.message }
      format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  private

  def apply_tabulator_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?

      case field
      when "status"
        scope = scope.where(status: value.to_s)
      when "severity"
        scope = scope.where(severity: value.to_s)
      when "issue_type"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(issue_type) LIKE ?", term)
      when "source"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(source) LIKE ?", term)
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
    when "last_seen_at"
      scope.order(Arel.sql("last_seen_at #{dir}, id #{dir}"))
    when "severity"
      scope.order(Arel.sql("severity #{dir}, last_seen_at DESC, id DESC"))
    when "status"
      scope.order(Arel.sql("status #{dir}, last_seen_at DESC, id DESC"))
    when "occurrences"
      scope.order(Arel.sql("occurrences #{dir}, last_seen_at DESC, id DESC"))
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

  def tabulator_payload(issues:, total:, pages:)
    data = issues.map do |issue|
      {
        id: issue.id,
        title: issue.title,
        issue_type: issue.issue_type,
        source: issue.source,
        severity: issue.severity,
        status: issue.status,
        details: issue.details.to_s,
        occurrences: issue.occurrences.to_i,
        first_seen_at: issue.first_seen_at&.iso8601,
        last_seen_at: issue.last_seen_at&.iso8601,
        instagram_account_id: issue.instagram_account_id,
        instagram_profile_id: issue.instagram_profile_id,
        retryable: issue.retryable?,
        failure_url: issue.background_job_failure ? Rails.application.routes.url_helpers.admin_background_job_failure_path(issue.background_job_failure) : nil,
        update_url: Rails.application.routes.url_helpers.admin_issue_path(issue),
        retry_url: Rails.application.routes.url_helpers.retry_job_admin_issue_path(issue)
      }
    end

    { data: data, last_page: pages, last_row: total }
  end
end
