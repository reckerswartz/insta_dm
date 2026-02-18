class Admin::BackgroundJobsController < Admin::BaseController
  def dashboard
    @backend = queue_backend

    if @backend == "sidekiq"
      load_sidekiq_dashboard!
    else
      load_solid_queue_dashboard!
    end
    attach_recent_job_details!

    @failure_logs = BackgroundJobFailure.recent_first.limit(100)
    @recent_issues = AppIssue.recent_first.limit(15)
    @recent_storage_ingestions = ActiveStorageIngestion.recent_first.limit(15)
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

  def retry_failure
    failure = BackgroundJobFailure.find(params[:id])
    Jobs::FailureRetry.enqueue!(failure)

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "job_failures_changed",
      account_id: failure.instagram_account_id,
      payload: { action: "retry", failure_id: failure.id },
      throttle_key: "job_failures_changed",
      throttle_seconds: 0
    )

    respond_to do |format|
      format.html { redirect_to admin_background_job_failure_path(failure), notice: "Retry queued for #{failure.job_class}." }
      format.json { render json: { ok: true } }
    end
  rescue Jobs::FailureRetry::RetryError => e
    respond_to do |format|
      format.html { redirect_to admin_background_job_failure_path(params[:id]), alert: e.message }
      format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def clear_all_jobs
    backend = queue_backend
    
    if backend == "sidekiq"
      clear_sidekiq_jobs!
    else
      clear_solid_queue_jobs!
    end

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "jobs_changed",
      payload: { action: "clear_all" },
      throttle_key: "jobs_changed",
      throttle_seconds: 0
    )
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
    solid_jobs = safe_query { SolidQueue::Job.order(created_at: :desc).limit(100).to_a } || []
    @recent_jobs = solid_jobs.map { |job| serialize_solid_queue_job(job) }
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
      active_job_id: wrapper["job_id"].to_s.presence,
      provider_job_id: wrapper["provider_job_id"].to_s.presence || item["jid"].to_s.presence,
      error_message: item["error_message"].to_s.presence,
      job_scope: context[:job_scope],
      context_label: context[:context_label],
      instagram_account_id: context[:instagram_account_id],
      instagram_profile_id: context[:instagram_profile_id],
      arguments: wrapper["arguments"] || item["args"] || []
    }
  rescue StandardError
    {
      created_at: nil,
      class_name: "unknown",
      queue_name: queue_name.to_s,
      status: status,
      jid: nil,
      active_job_id: nil,
      provider_job_id: nil,
      error_message: nil,
      job_scope: "system",
      context_label: "System",
      instagram_account_id: nil,
      instagram_profile_id: nil,
      arguments: []
    }
  end

  def serialize_solid_queue_job(job)
    args = job.respond_to?(:arguments) ? job.arguments : {}
    context = Jobs::ContextExtractor.from_solid_queue_job_arguments(args)

    status =
      if job.respond_to?(:finished_at) && job.finished_at.present?
        "finished"
      elsif job.respond_to?(:scheduled_at) && job.scheduled_at.present?
        "scheduled"
      else
        "running/queued"
      end

    {
      created_at: (job.created_at if job.respond_to?(:created_at)),
      class_name: (job.class_name if job.respond_to?(:class_name)) || "unknown",
      queue_name: (job.queue_name if job.respond_to?(:queue_name)).to_s,
      status: status,
      jid: (job.id.to_s if job.respond_to?(:id)),
      active_job_id: (job.active_job_id.to_s if job.respond_to?(:active_job_id)).presence,
      provider_job_id: nil,
      error_message: nil,
      job_scope: context[:job_scope],
      context_label: context[:context_label],
      instagram_account_id: context[:instagram_account_id],
      instagram_profile_id: context[:instagram_profile_id],
      arguments: args || []
    }
  rescue StandardError
    {
      created_at: nil,
      class_name: "unknown",
      queue_name: "",
      status: "unknown",
      jid: nil,
      active_job_id: nil,
      provider_job_id: nil,
      error_message: nil,
      job_scope: "system",
      context_label: "System",
      instagram_account_id: nil,
      instagram_profile_id: nil,
      arguments: []
    }
  end

  def attach_recent_job_details!
    rows = Array(@recent_jobs)
    return if rows.empty?

    active_job_ids = rows.map { |row| row[:active_job_id].to_s.presence }.compact.uniq
    action_logs_by_job_id = load_action_logs_by_job_id(active_job_ids: active_job_ids)
    failures_by_job_id = load_failures_by_job_id(active_job_ids: active_job_ids)
    ingestions_by_job_id = load_ingestions_by_job_id(active_job_ids: active_job_ids)
    llm_events_by_job_id = load_llm_events_by_job_id(active_job_ids: active_job_ids)
    api_calls_by_job_id = load_api_calls_by_job_id(active_job_ids: active_job_ids)

    rows.each do |row|
      active_job_id = row[:active_job_id].to_s
      action_log = action_logs_by_job_id[active_job_id]&.first
      failure = failures_by_job_id[active_job_id]&.first
      direct_ingestions = ingestions_by_job_id[active_job_id] || []
      direct_llm_events = llm_events_by_job_id[active_job_id] || []
      direct_api_calls = api_calls_by_job_id[active_job_id] || []

      row[:details] = build_job_details(
        row: row,
        action_log: action_log,
        failure: failure,
        direct_ingestions: direct_ingestions,
        direct_llm_events: direct_llm_events,
        direct_api_calls: direct_api_calls
      )
    end
  rescue StandardError
    rows.each { |row| row[:details] = fallback_job_details(row: row) }
  end

  def load_action_logs_by_job_id(active_job_ids:)
    return {} if active_job_ids.empty?

    InstagramProfileActionLog
      .includes(:instagram_account, :instagram_profile)
      .where(active_job_id: active_job_ids)
      .order(created_at: :desc)
      .to_a
      .group_by { |row| row.active_job_id.to_s }
  rescue StandardError
    {}
  end

  def load_failures_by_job_id(active_job_ids:)
    return {} if active_job_ids.empty?

    BackgroundJobFailure
      .where(active_job_id: active_job_ids)
      .order(occurred_at: :desc, id: :desc)
      .to_a
      .group_by { |row| row.active_job_id.to_s }
  rescue StandardError
    {}
  end

  def load_ingestions_by_job_id(active_job_ids:)
    return {} if active_job_ids.empty?

    ActiveStorageIngestion
      .where(created_by_active_job_id: active_job_ids)
      .order(created_at: :desc, id: :desc)
      .limit(400)
      .to_a
      .group_by { |row| row.created_by_active_job_id.to_s }
  rescue StandardError
    {}
  end

  def load_llm_events_by_job_id(active_job_ids:)
    return {} if active_job_ids.empty?

    InstagramProfileEvent
      .where(llm_comment_job_id: active_job_ids)
      .order(updated_at: :desc, id: :desc)
      .limit(300)
      .to_a
      .group_by { |row| row.llm_comment_job_id.to_s }
  rescue StandardError
    {}
  end

  def load_api_calls_by_job_id(active_job_ids:)
    return {} if active_job_ids.empty?

    index = Hash.new { |h, k| h[k] = [] }
    AiApiCall.recent_first.limit(600).to_a.each do |call|
      metadata = call.metadata.is_a?(Hash) ? call.metadata : {}
      active_job_id = metadata["active_job_id"].to_s
      next if active_job_id.blank? || !active_job_ids.include?(active_job_id)

      index[active_job_id] << call
    end
    index
  rescue StandardError
    {}
  end

  def build_job_details(row:, action_log:, failure:, direct_ingestions:, direct_llm_events:, direct_api_calls:)
    window = inferred_time_window(row: row, action_log: action_log, failure: failure)
    api_calls = direct_api_calls.presence || fallback_api_calls(row: row, window: window)
    ingestions = direct_ingestions.presence || fallback_ingestions(row: row, window: window)
    llm_events = direct_llm_events.presence || fallback_llm_events(row: row, window: window)
    ai_analyses = related_ai_analyses(row: row, action_log: action_log, window: window)
    story_rows = related_story_rows(row: row, window: window)

    processing_steps = build_processing_steps(
      row: row,
      action_log: action_log,
      failure: failure,
      api_calls: api_calls,
      ingestions: ingestions,
      llm_events: llm_events,
      ai_analyses: ai_analyses,
      story_rows: story_rows
    )

    final_output = build_final_output(row: row, action_log: action_log, failure: failure)
    technical_data = build_technical_data(action_log: action_log, llm_events: llm_events, ai_analyses: ai_analyses, story_rows: story_rows)

    {
      processing_steps: processing_steps,
      final_output: final_output,
      api_responses: api_calls.first(8).map { |call| serialize_api_call(call) },
      technical_data: technical_data,
      blobs: ingestions.first(10).map { |row_item| serialize_ingestion(row_item) }
    }
  rescue StandardError
    fallback_job_details(row: row)
  end

  def fallback_job_details(row:)
    {
      processing_steps: [ "No detailed processing records were linked to this job yet." ],
      final_output: {
        status: row[:status].to_s,
        summary: row[:error_message].to_s.presence || "No final output captured yet."
      }.compact,
      api_responses: [],
      technical_data: [],
      blobs: []
    }
  end

  def inferred_time_window(row:, action_log:, failure:)
    started_candidates = [
      action_log&.started_at,
      action_log&.occurred_at,
      row[:created_at],
      failure&.occurred_at
    ].compact
    ended_candidates = [
      action_log&.finished_at,
      failure&.occurred_at,
      row[:created_at]
    ].compact
    return nil if started_candidates.empty? && ended_candidates.empty?

    started_at = (started_candidates.min || ended_candidates.min) - 20.minutes
    ended_at = (ended_candidates.max || started_at + 2.hours) + 20.minutes
    started_at..ended_at
  rescue StandardError
    nil
  end

  def fallback_api_calls(row:, window:)
    account_id = row[:instagram_account_id].to_i
    return [] unless account_id.positive?

    scope = AiApiCall.where(instagram_account_id: account_id).order(occurred_at: :desc, id: :desc)
    scope = scope.where(occurred_at: window) if window
    scope.limit(8).to_a
  rescue StandardError
    []
  end

  def fallback_ingestions(row:, window:)
    scope = ActiveStorageIngestion.order(created_at: :desc, id: :desc)
    profile_id = row[:instagram_profile_id].to_i
    account_id = row[:instagram_account_id].to_i
    return [] unless profile_id.positive? || account_id.positive?

    scope = scope.where(instagram_profile_id: profile_id) if profile_id.positive?
    scope = scope.where(instagram_account_id: account_id) if !profile_id.positive? && account_id.positive?
    scope = scope.where(created_at: window) if window
    scope.limit(10).to_a
  rescue StandardError
    []
  end

  def fallback_llm_events(row:, window:)
    profile_id = row[:instagram_profile_id].to_i
    return [] unless profile_id.positive?

    scope = InstagramProfileEvent.where(instagram_profile_id: profile_id).order(updated_at: :desc, id: :desc)
    scope = scope.where(updated_at: window) if window
    scope.limit(6).to_a.select do |event|
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      raw_meta = event.metadata.is_a?(Hash) ? event.metadata : {}
      llm_meta.present? || raw_meta["processing_metadata"].is_a?(Hash) || raw_meta["local_story_intelligence"].is_a?(Hash)
    end
  rescue StandardError
    []
  end

  def related_ai_analyses(row:, action_log:, window:)
    account_id = row[:instagram_account_id].to_i
    return [] unless account_id.positive?

    scope = AiAnalysis.where(instagram_account_id: account_id).order(created_at: :desc, id: :desc)
    scope = scope.where(created_at: window) if window

    profile_id = row[:instagram_profile_id].to_i
    if profile_id.positive?
      scope = scope.where(analyzable_type: "InstagramProfile", analyzable_id: profile_id)
    end

    purpose_hint = purpose_hint_for(row: row, action_log: action_log)
    scope = scope.where(purpose: purpose_hint) if purpose_hint.present?

    scope.limit(6).to_a
  rescue StandardError
    []
  end

  def purpose_hint_for(row:, action_log:)
    klass = row[:class_name].to_s
    action = action_log&.action.to_s
    return "post" if klass.include?("AnalyzeInstagramPostJob") || action == "capture_profile_posts" || action == "analyze_profile_posts"
    return "profile" if klass.include?("AnalyzeInstagramProfileJob") || action == "analyze_profile"

    nil
  end

  def related_story_rows(row:, window:)
    profile_id = row[:instagram_profile_id].to_i
    return [] unless profile_id.positive?

    scope = InstagramStory.where(instagram_profile_id: profile_id).order(updated_at: :desc, id: :desc)
    scope = scope.where(updated_at: window) if window
    scope.limit(6).to_a.select do |story|
      metadata = story.metadata.is_a?(Hash) ? story.metadata : {}
      metadata["processing_metadata"].is_a?(Hash) ||
        metadata["generated_response_suggestions"].present? ||
        metadata["content_understanding"].is_a?(Hash)
    end
  rescue StandardError
    []
  end

  def build_processing_steps(row:, action_log:, failure:, api_calls:, ingestions:, llm_events:, ai_analyses:, story_rows:)
    steps = []
    if row[:created_at].present?
      steps << "Queued in #{row[:queue_name].to_s.presence || '-'} at #{row[:created_at].iso8601}."
    else
      steps << "Queued in #{row[:queue_name].to_s.presence || '-'}."
    end

    if action_log
      steps << "Action log '#{action_log.action}' recorded with status '#{action_log.status}'."
      steps << "Execution started at #{action_log.started_at.iso8601}." if action_log.started_at.present?
      steps << "Execution finished at #{action_log.finished_at.iso8601}." if action_log.finished_at.present?
    end
    steps << "Captured #{api_calls.length} related API call(s)." if api_calls.any?
    steps << "Generated #{ai_analyses.length} AI analysis record(s)." if ai_analyses.any?
    steps << "Updated #{llm_events.length} LLM/story event record(s)." if llm_events.any?
    steps << "Persisted #{story_rows.length} story processing artifact(s)." if story_rows.any?
    steps << "Stored #{ingestions.length} blob/file ingestion record(s)." if ingestions.any?
    if failure
      steps << "Failed at #{failure.occurred_at&.iso8601 || 'unknown time'} with #{failure.error_class}: #{failure.error_message.to_s.byteslice(0, 240)}"
    end

    steps.uniq.first(12)
  end

  def build_final_output(row:, action_log:, failure:)
    {
      status: action_log&.status.to_s.presence || (failure.present? ? "failed" : row[:status].to_s),
      summary: action_log&.log_text.to_s.presence || failure&.error_message.to_s.presence || row[:error_message].to_s.presence || "No final output captured yet.",
      error_class: failure&.error_class.to_s.presence,
      error_message: action_log&.error_message.to_s.presence || failure&.error_message.to_s.presence || row[:error_message].to_s.presence,
      metadata: compact_data(action_log&.metadata)
    }.compact
  end

  def build_technical_data(action_log:, llm_events:, ai_analyses:, story_rows:)
    rows = []
    rows << {
      source: "profile_action_log",
      payload: compact_data(action_log.metadata)
    } if action_log&.metadata.is_a?(Hash)

    llm_events.first(4).each do |event|
      rows << {
        source: "instagram_profile_event",
        payload: {
          event_id: event.id,
          event_kind: event.kind,
          llm_comment_status: event.llm_comment_status,
          llm_comment_model: event.llm_comment_model,
          llm_comment_provider: event.llm_comment_provider,
          generated_comment: event.llm_generated_comment.to_s.presence&.byteslice(0, 280),
          relevance_score: event.llm_comment_relevance_score,
          llm_comment_metadata: compact_data(event.llm_comment_metadata),
          metadata: compact_data(event.metadata)
        }.compact
      }
    end

    ai_analyses.first(4).each do |analysis|
      rows << {
        source: "ai_analysis",
        payload: {
          analysis_id: analysis.id,
          purpose: analysis.purpose,
          provider: analysis.provider,
          model: analysis.model,
          status: analysis.status,
          started_at: analysis.started_at&.iso8601,
          finished_at: analysis.finished_at&.iso8601,
          response_excerpt: analysis.response_text.to_s.presence&.byteslice(0, 320),
          analysis: compact_data(analysis.analysis),
          metadata: compact_data(analysis.metadata)
        }.compact
      }
    end

    story_rows.first(4).each do |story|
      metadata = story.metadata.is_a?(Hash) ? story.metadata : {}
      rows << {
        source: "instagram_story",
        payload: {
          story_id: story.story_id,
          media_type: story.media_type,
          processing_status: story.processing_status,
          processed: story.processed,
          processed_at: story.processed_at&.iso8601,
          metadata: compact_data(
            metadata.slice(
              "processing_metadata",
              "generated_response_suggestions",
              "content_understanding",
              "face_count",
              "content_signals",
              "ocr_text",
              "transcript",
              "object_detections",
              "scenes"
            )
          )
        }.compact
      }
    end

    rows.first(12)
  end

  def serialize_api_call(call)
    metadata = call.metadata.is_a?(Hash) ? call.metadata : {}
    {
      occurred_at: call.occurred_at&.iso8601,
      provider: call.provider,
      operation: call.operation,
      category: call.category,
      status: call.status,
      http_status: call.http_status,
      latency_ms: call.latency_ms,
      input_tokens: call.input_tokens,
      output_tokens: call.output_tokens,
      total_tokens: call.total_tokens,
      error_message: call.error_message.to_s.presence,
      metadata: compact_data(metadata)
    }.compact
  end

  def serialize_ingestion(row)
    {
      created_at: row.created_at&.iso8601,
      attachment_name: row.attachment_name,
      record_type: row.record_type,
      record_id: row.record_id,
      blob_filename: row.blob_filename,
      blob_content_type: row.blob_content_type,
      blob_byte_size: row.blob_byte_size,
      metadata: compact_data(row.metadata)
    }.compact
  end

  def compact_data(value, depth: 0, max_depth: 3)
    return nil if value.nil?
    return "[depth_limit]" if depth >= max_depth

    case value
    when Hash
      compacted = {}
      value.to_h.each do |key, item|
        normalized = compact_data(item, depth: depth + 1, max_depth: max_depth)
        next if normalized.blank? && normalized != false && normalized != 0

        compacted[key.to_s] = normalized
        break if compacted.length >= 20
      end
      compacted
    when Array
      value.first(10).map { |item| compact_data(item, depth: depth + 1, max_depth: max_depth) }.compact
    when String
      text = value.to_s.strip
      return nil if text.blank?

      text.byteslice(0, 320)
    when Time, Date, DateTime
      value.iso8601
    else
      value
    end
  rescue StandardError
    value.to_s.byteslice(0, 320)
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
      when "failure_kind"
        scope = scope.where(failure_kind: value.to_s)
      when "retryable"
        parsed = ActiveModel::Type::Boolean.new.cast(value)
        scope = scope.where(retryable: parsed)
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
    when "failure_kind"
      scope.order(Arel.sql("failure_kind #{dir}, occurred_at DESC, id DESC"))
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
        failure_kind: f.failure_kind,
        retryable: f.retryable_now?,
        error_class: f.error_class,
        error_message: f.error_message,
        open_url: Rails.application.routes.url_helpers.admin_background_job_failure_path(f),
        retry_url: Rails.application.routes.url_helpers.admin_retry_background_job_failure_path(f)
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
