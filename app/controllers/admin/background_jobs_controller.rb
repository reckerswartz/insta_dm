class Admin::BackgroundJobsController < Admin::BaseController
  def dashboard
    @backend = queue_backend

    if @backend == "sidekiq"
      load_sidekiq_dashboard!
    else
      load_solid_queue_dashboard!
    end

    @failure_logs = BackgroundJobFailure.order(occurred_at: :desc).limit(100)
  end

  def failures
    scope = BackgroundJobFailure.order(occurred_at: :desc, id: :desc)
    scope = apply_tabulator_filters(scope)

    @q = params[:q].to_s.strip
    if @q.present?
      term = "%#{@q.downcase}%"
      scope = scope.where(
        "LOWER(job_class) LIKE ? OR LOWER(COALESCE(queue_name, '')) LIKE ? OR LOWER(error_class) LIKE ? OR LOWER(error_message) LIKE ?",
        term, term, term, term
      )
    end

    scope = apply_remote_sort(scope) || scope

    page = params.fetch(:page, 1).to_i
    page = 1 if page < 1

    per_page_param = params[:per_page].presence || params[:size].presence
    per_page = per_page_param.to_i
    per_page = 50 if per_page <= 0
    per_page = per_page.clamp(10, 200)

    total = scope.count
    pages = (total / per_page.to_f).ceil
    @failures = scope.offset((page - 1) * per_page).limit(per_page)

    respond_to do |format|
      format.html
      format.json do
        render json: tabulator_payload(failures: @failures, total: total, pages: pages)
      end
    end
  end

  def failure
    @failure = BackgroundJobFailure.find(params[:id])
  end

  def clear_all_jobs
    backend = queue_backend
    
    if backend == "sidekiq"
      clear_sidekiq_jobs!
    else
      clear_solid_queue_jobs!
    end

    redirect_to admin_background_jobs_path, notice: "All jobs have been stopped and queue cleared successfully."
  rescue StandardError => e
    redirect_to admin_background_jobs_path, alert: "Failed to clear jobs: #{e.message}"
  end

  private

  def queue_backend
    Rails.application.config.active_job.queue_adapter.to_s
  rescue StandardError
    "unknown"
  end

  def load_solid_queue_dashboard!
    @counts = {
      ready: safe_count { SolidQueue::ReadyExecution.count },
      scheduled: safe_count { SolidQueue::ScheduledExecution.count },
      claimed: safe_count { SolidQueue::ClaimedExecution.count },
      blocked: safe_count { SolidQueue::BlockedExecution.count },
      failed: safe_count { SolidQueue::FailedExecution.count },
      pauses: safe_count { SolidQueue::Pause.count },
      jobs_total: safe_count { SolidQueue::Job.count }
    }

    @processes = safe_query { SolidQueue::Process.order(last_heartbeat_at: :desc).limit(50).to_a } || []
    @recent_jobs = safe_query { SolidQueue::Job.order(created_at: :desc).limit(100).to_a } || []
    @recent_failed = safe_query do
      SolidQueue::FailedExecution
        .includes(:job)
        .order(created_at: :desc)
        .limit(50)
        .to_a
    end || []
  end

  def load_sidekiq_dashboard!
    require "sidekiq/api"

    queues = safe_query { Sidekiq::Queue.all } || []
    scheduled = Sidekiq::ScheduledSet.new
    retries = Sidekiq::RetrySet.new
    dead = Sidekiq::DeadSet.new
    processes = Sidekiq::ProcessSet.new

    queue_rows = queues.map { |queue| { name: queue.name, size: queue.size } }
    @counts = {
      enqueued: queue_rows.sum { |row| row[:size].to_i },
      scheduled: safe_count { scheduled.size },
      retries: safe_count { retries.size },
      dead: safe_count { dead.size },
      processes: safe_count { processes.size },
      queues: queue_rows
    }

    @processes = safe_query do
      processes.map do |p|
        {
          identity: p["identity"],
          hostname: p["hostname"],
          pid: p["pid"],
          queues: Array(p["queues"]),
          labels: Array(p["labels"]),
          busy: p["busy"].to_i,
          beat: parse_time(p["beat"])
        }
      end.sort_by { |row| row[:beat] || Time.at(0) }.reverse.first(50)
    end || []

    enqueued_rows = queues.flat_map do |queue|
      queue.first(30).map { |job| serialize_sidekiq_job(job: job, status: "enqueued", queue_name: queue.name) }
    end
    scheduled_rows = scheduled.first(30).map { |job| serialize_sidekiq_job(job: job, status: "scheduled", queue_name: job.queue) }
    retry_rows = retries.first(20).map { |job| serialize_sidekiq_job(job: job, status: "retry", queue_name: job.queue) }
    dead_rows = dead.first(20).map { |job| serialize_sidekiq_job(job: job, status: "dead", queue_name: job.queue) }

    @recent_jobs = (enqueued_rows + scheduled_rows + retry_rows + dead_rows)
      .sort_by { |row| row[:created_at] || Time.at(0) }
      .reverse
      .first(100)

    @recent_failed = (retry_rows + dead_rows).first(50)
  rescue StandardError
    @counts = { enqueued: 0, scheduled: 0, retries: 0, dead: 0, processes: 0, queues: [] }
    @processes = []
    @recent_jobs = []
    @recent_failed = []
  end

  def serialize_sidekiq_job(job:, status:, queue_name:)
    item = job.item.to_h
    wrapper = active_job_wrapper_from_sidekiq(item)
    context = Jobs::ContextExtractor.from_active_job_arguments(wrapper["arguments"] || item["args"])
    {
      created_at: parse_time(item["created_at"] || item["enqueued_at"] || item["at"]),
      class_name: wrapper["job_class"].presence || item["wrapped"].presence || item["class"].to_s,
      queue_name: queue_name.to_s,
      status: status,
      jid: item["jid"].to_s,
      error_message: item["error_message"].to_s.presence,
      job_scope: context[:job_scope],
      context_label: context[:context_label],
      arguments: wrapper["arguments"] || item["args"] || []
    }
  rescue StandardError
    {
      created_at: nil,
      class_name: "unknown",
      queue_name: queue_name.to_s,
      status: status,
      jid: nil,
      error_message: nil,
      job_scope: "system",
      context_label: "System",
      arguments: []
    }
  end

  def active_job_wrapper_from_sidekiq(item)
    args = Array(item["args"])
    first = args.first
    return first.to_h if first.respond_to?(:to_h) && first.to_h["job_class"].present?

    {}
  rescue StandardError
    {}
  end

  def parse_time(value)
    return nil if value.blank?

    Time.at(value.to_f)
  rescue StandardError
    nil
  end

  def safe_count
    yield
  rescue StandardError
    0
  end

  def safe_query
    yield
  rescue StandardError
    nil
  end

  def apply_tabulator_filters(scope)
    extract_tabulator_filters.each do |f|
      field = f[:field]
      value = f[:value]
      next if value.blank?

      case field
      when "job_class"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(job_class) LIKE ?", term)
      when "queue_name"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(queue_name,'')) LIKE ?", term)
      when "error_message"
        term = "%#{value.downcase}%"
        scope = scope.where("LOWER(COALESCE(error_message,'')) LIKE ?", term)
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
    when "occurred_at"
      scope.order(Arel.sql("occurred_at #{dir}, id #{dir}"))
    when "job_class"
      scope.order(Arel.sql("job_class #{dir}, occurred_at DESC, id DESC"))
    when "queue_name"
      scope.order(Arel.sql("queue_name #{dir} NULLS LAST, occurred_at DESC, id DESC"))
    when "error_class"
      scope.order(Arel.sql("error_class #{dir}, occurred_at DESC, id DESC"))
    else
      nil
    end
  end

  def tabulator_payload(failures:, total:, pages:)
    data = failures.map do |f|
      scope = failure_scope(f)
      {
        id: f.id,
        occurred_at: f.occurred_at&.iso8601,
        job_scope: scope,
        context_label: failure_context_label(f, scope: scope),
        instagram_account_id: f.instagram_account_id,
        instagram_profile_id: f.instagram_profile_id,
        job_class: f.job_class,
        queue_name: f.queue_name,
        error_class: f.error_class,
        error_message: f.error_message,
        open_url: Rails.application.routes.url_helpers.admin_background_job_failure_path(f)
      }
    end

    {
      data: data,
      last_page: pages,
      last_row: total
    }
  end

  def failure_scope(failure)
    return "profile" if failure.instagram_profile_id.present?
    return "account" if failure.instagram_account_id.present?
    "system"
  end

  def failure_context_label(failure, scope:)
    case scope
    when "profile"
      "Profile ##{failure.instagram_profile_id} (Account ##{failure.instagram_account_id || '?'})"
    when "account"
      "Account ##{failure.instagram_account_id}"
    else
      "System"
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

  def clear_sidekiq_jobs!
    require "sidekiq/api"
    
    # Clear all queues
    Sidekiq::Queue.all.each(&:clear)
    
    # Clear scheduled jobs
    Sidekiq::ScheduledSet.new.clear
    
    # Clear retry jobs
    Sidekiq::RetrySet.new.clear
    
    # Clear dead jobs
    Sidekiq::DeadSet.new.clear
    
    # Stop all processes by sending quiet signal
    Sidekiq::ProcessSet.new.each do |process|
      process.quiet! if process.alive?
    end
  end

  def clear_solid_queue_jobs!
    # Clear all job executions
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::ScheduledExecution.delete_all
    SolidQueue::ClaimedExecution.delete_all
    SolidQueue::BlockedExecution.delete_all
    SolidQueue::FailedExecution.delete_all
    SolidQueue::Job.delete_all
    
    # Stop all processes
    SolidQueue::Process.delete_all
  end
end
