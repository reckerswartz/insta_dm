require "digest"
require "json"
require "set"

class BuildInstagramProfileHistoryJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:profile_history_build)

  PROFILE_INCOMPLETE_REASON_CODES =
    if defined?(ProcessPostMetadataTaggingJob::PROFILE_INCOMPLETE_REASON_CODES)
      ProcessPostMetadataTaggingJob::PROFILE_INCOMPLETE_REASON_CODES
    else
      %w[
        latest_posts_not_analyzed
        insufficient_analyzed_posts
        no_recent_posts_available
        missing_structured_post_signals
        profile_preparation_failed
        profile_preparation_error
      ].freeze
    end

  MAX_RETRY_ATTEMPTS = ENV.fetch("PROFILE_HISTORY_BUILD_MAX_RETRY_ATTEMPTS", 8).to_i.clamp(1, 30)
  SHORT_RETRY_WAIT_MINUTES = ENV.fetch("PROFILE_HISTORY_BUILD_RETRY_WAIT_MINUTES", 45).to_i.clamp(10, 240)
  FACE_REFRESH_RETRY_WAIT_MINUTES = ENV.fetch("PROFILE_HISTORY_BUILD_FACE_REFRESH_RETRY_WAIT_MINUTES", 15).to_i.clamp(5, 120)
  LONG_RETRY_WAIT_HOURS = ENV.fetch("PROFILE_HISTORY_BUILD_RETRY_WAIT_HOURS", 4).to_i.clamp(1, 24)
  ACTIVE_LOG_LOOKBACK_HOURS = ENV.fetch("PROFILE_HISTORY_BUILD_ACTIVE_LOG_LOOKBACK_HOURS", 12).to_i.clamp(1, 72)

  class << self
    def enqueue_with_resume_if_needed!(account:, profile:, trigger_source:, requested_by:, resume_job: nil)
      raise ArgumentError, "account is required" unless account
      raise ArgumentError, "profile is required" unless profile

      serialized_resume = serialize_resume_job(resume_job)
      active_log = active_build_history_log(profile: profile)

      if active_log
        register_pending_resume_jobs!(log: active_log, jobs: [ serialized_resume ].compact, requested_by: requested_by)
        return {
          accepted: true,
          queued: false,
          registered: serialized_resume.present?,
          reason: "build_history_already_running",
          action_log_id: active_log.id,
          job_id: active_log.active_job_id,
          next_run_at: active_log.metadata.is_a?(Hash) ? active_log.metadata.dig("retry", "next_run_at") : nil
        }
      end

      metadata = {
        requested_by: requested_by.to_s.presence || name,
        trigger_source: trigger_source.to_s.presence || "system"
      }
      metadata["pending_resume_jobs"] = [ serialized_resume ] if serialized_resume

      log = profile.instagram_profile_action_logs.create!(
        instagram_account: account,
        action: "build_history",
        status: "queued",
        trigger_source: trigger_source.to_s.presence || "system",
        occurred_at: Time.current,
        metadata: metadata
      )

      job = perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: log.id
      )
      log.update!(active_job_id: job.job_id, queue_name: job.queue_name)

      {
        accepted: true,
        queued: true,
        registered: serialized_resume.present?,
        reason: "build_history_queued",
        action_log_id: log.id,
        job_id: job.job_id,
        next_run_at: nil
      }
    rescue StandardError => e
      {
        accepted: false,
        queued: false,
        registered: false,
        reason: "build_history_enqueue_failed",
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    end

    def serialize_resume_job(resume_job)
      return nil unless resume_job.is_a?(Hash)

      raw_job_class = resume_job[:job_class] || resume_job["job_class"]
      raw_kwargs = resume_job[:job_kwargs] || resume_job["job_kwargs"]
      job_class_name =
        case raw_job_class
        when Class
          raw_job_class.name
        else
          raw_job_class.to_s
        end
      return nil if job_class_name.blank?

      kwargs = raw_kwargs.is_a?(Hash) ? raw_kwargs.deep_stringify_keys : {}
      {
        "job_class" => job_class_name,
        "job_kwargs" => kwargs,
        "fingerprint" => resume_fingerprint(job_class_name: job_class_name, job_kwargs: kwargs),
        "registered_at" => Time.current.iso8601(3)
      }
    rescue StandardError
      nil
    end

    private

    def active_build_history_log(profile:)
      profile.instagram_profile_action_logs
        .where(action: "build_history", status: %w[queued running])
        .where("created_at >= ?", ACTIVE_LOG_LOOKBACK_HOURS.hours.ago)
        .order(created_at: :desc)
        .first
    end

    def register_pending_resume_jobs!(log:, jobs:, requested_by:)
      valid_jobs = Array(jobs).select { |row| row.is_a?(Hash) }
      return if valid_jobs.empty?

      log.with_lock do
        metadata = log.metadata.is_a?(Hash) ? log.metadata.deep_dup : {}
        pending = Array(metadata["pending_resume_jobs"]).select { |row| row.is_a?(Hash) }
        existing_fingerprints = pending.map { |row| row["fingerprint"].to_s }.reject(&:blank?).to_set

        valid_jobs.each do |row|
          fingerprint = row["fingerprint"].to_s
          next if fingerprint.present? && existing_fingerprints.include?(fingerprint)

          pending << row
          existing_fingerprints << fingerprint if fingerprint.present?
        end

        metadata["pending_resume_jobs"] = pending
        metadata["last_resume_registration_at"] = Time.current.iso8601(3)
        metadata["requested_by"] = requested_by.to_s if requested_by.to_s.present?
        log.update!(metadata: metadata)
      end
    rescue StandardError
      nil
    end

    def resume_fingerprint(job_class_name:, job_kwargs:)
      normalized = normalize_for_fingerprint(job_kwargs)
      Digest::SHA256.hexdigest("#{job_class_name}:#{JSON.generate(normalized)}")
    rescue StandardError
      Digest::SHA256.hexdigest("#{job_class_name}:#{job_kwargs}")
    end

    def normalize_for_fingerprint(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, hash|
          hash[key] = normalize_for_fingerprint(value[key] || value[key.to_sym])
        end
      when Array
        value.map { |row| normalize_for_fingerprint(row) }
      else
        value
      end
    end
  end

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil, attempts: 0, resume_job: nil)
    account = InstagramAccount.find_by(id: instagram_account_id)
    unless account
      Ops::StructuredLogger.info(
        event: "profile_history_build.skipped_missing_account",
        payload: {
          instagram_account_id: instagram_account_id,
          instagram_profile_id: instagram_profile_id
        }
      )
      return
    end

    profile = account.instagram_profiles.find_by(id: instagram_profile_id)
    unless profile
      Ops::StructuredLogger.info(
        event: "profile_history_build.skipped_missing_profile",
        payload: {
          instagram_account_id: account.id,
          instagram_profile_id: instagram_profile_id
        }
      )
      return
    end

    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      profile_action_log_id: profile_action_log_id
    )
    register_incoming_resume_job!(action_log: action_log, resume_job: resume_job)
    action_log.mark_running!(extra_metadata: {
      queue_name: queue_name,
      active_job_id: job_id,
      attempts: attempts.to_i
    })

    result = Ai::ProfileHistoryBuildService.new(account: account, profile: profile).execute!
    history_state = result[:history_state].is_a?(Hash) ? result[:history_state] : {}
    reason_code = result[:reason_code].to_s
    reason = result[:reason].to_s
    status = result[:status].to_s
    payload = {
      attempts: attempts.to_i,
      status: status,
      reason_code: reason_code.presence,
      reason: reason.presence,
      history_build: history_state
    }.compact

    case status
    when "ready"
      resume_state = enqueue_pending_resume_jobs!(action_log: action_log, resume_job: resume_job)
      action_log.mark_succeeded!(
        extra_metadata: payload.merge(
          resume: resume_state
        ),
        log_text: "History Ready for #{profile.username}."
      )
    when "blocked"
      action_log.mark_succeeded!(
        extra_metadata: payload.merge(skipped: true),
        log_text: reason.presence || "History build skipped by policy."
      )
    else
      retry_state = schedule_retry!(
        account: account,
        profile: profile,
        action_log: action_log,
        attempts: attempts.to_i,
        reason_code: reason_code
      )
      if retry_state[:queued]
        queue_payload = payload.merge(
          retry: {
            queued: true,
            next_run_at: retry_state[:next_run_at].iso8601(3),
            retry_job_id: retry_state[:job_id],
            wait_seconds: retry_state[:wait_seconds]
          }
        )
        action_log.update!(
          status: "queued",
          finished_at: nil,
          metadata: merge_metadata(action_log.metadata, queue_payload),
          error_message: nil,
          log_text: "History build pending (#{reason_code.presence || 'in_progress'}). Retry scheduled at #{retry_state[:next_run_at].in_time_zone.iso8601}."
        )
      else
        exhausted_payload = payload.merge(
          retry: retry_state.except(:queued)
        )
        action_log.mark_failed!(
          error_message: "History build pending and retry unavailable (#{reason_code.presence || retry_state[:reason]}).",
          extra_metadata: exhausted_payload
        )
      end
    end
  rescue StandardError => e
    action_log&.mark_failed!(
      error_message: e.message,
      extra_metadata: {
        active_job_id: job_id,
        attempts: attempts.to_i
      }
    )
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "build_history",
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def schedule_retry!(account:, profile:, action_log:, attempts:, reason_code:)
    return { queued: false, reason: "max_attempts_reached" } if attempts >= MAX_RETRY_ATTEMPTS

    wait_seconds = retry_wait_seconds_for(reason_code: reason_code)
    run_at = Time.current + wait_seconds.seconds
    job = self.class.set(wait_until: run_at).perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: action_log.id,
      attempts: attempts + 1
    )

    {
      queued: true,
      wait_seconds: wait_seconds,
      next_run_at: run_at,
      job_id: job.job_id
    }
  rescue StandardError => e
    {
      queued: false,
      reason: "retry_enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def retry_wait_seconds_for(reason_code:)
    code = reason_code.to_s
    if code == "waiting_for_face_refresh"
      FACE_REFRESH_RETRY_WAIT_MINUTES.minutes.to_i
    elsif PROFILE_INCOMPLETE_REASON_CODES.include?(code)
      LONG_RETRY_WAIT_HOURS.hours.to_i
    else
      SHORT_RETRY_WAIT_MINUTES.minutes.to_i
    end
  end

  def merge_metadata(base, extra)
    current = base.is_a?(Hash) ? base : {}
    current.merge(extra.to_h)
  end

  def register_incoming_resume_job!(action_log:, resume_job:)
    serialized = self.class.send(:serialize_resume_job, resume_job)
    return unless serialized

    self.class.send(
      :register_pending_resume_jobs!,
      log: action_log,
      jobs: [ serialized ],
      requested_by: action_log.metadata.is_a?(Hash) ? action_log.metadata["requested_by"] : nil
    )
  rescue StandardError
    nil
  end

  def enqueue_pending_resume_jobs!(action_log:, resume_job:)
    additional = self.class.send(:serialize_resume_job, resume_job)
    pending = Array(action_log.metadata.is_a?(Hash) ? action_log.metadata["pending_resume_jobs"] : nil)
    pending = pending.select { |row| row.is_a?(Hash) }
    pending << additional if additional
    pending = dedupe_resume_jobs(rows: pending)
    return { pending_count: 0, resumed_count: 0, failed_count: 0, failures: [] } if pending.empty?

    resumed = []
    failures = []
    still_pending = []

    pending.each do |row|
      job_class_name = row["job_class"].to_s
      job_class = job_class_name.safe_constantize
      unless job_class.respond_to?(:perform_later)
        failure = row.merge(
          "error_class" => "UnresumableJobClass",
          "error_message" => "Job class not found or not resumable: #{job_class_name}",
          "failed_at" => Time.current.iso8601(3)
        )
        failures << failure
        still_pending << row
        next
      end

      kwargs = row["job_kwargs"].is_a?(Hash) ? row["job_kwargs"].deep_symbolize_keys : {}
      job = job_class.perform_later(**kwargs)
      resumed << row.merge(
        "resumed_job_id" => job.job_id,
        "resumed_queue_name" => job.queue_name,
        "resumed_at" => Time.current.iso8601(3)
      )
    rescue StandardError => e
      failure = row.merge(
        "error_class" => e.class.name,
        "error_message" => e.message.to_s,
        "failed_at" => Time.current.iso8601(3)
      )
      failures << failure
      still_pending << row
    end

    action_log.with_lock do
      metadata = action_log.metadata.is_a?(Hash) ? action_log.metadata.deep_dup : {}
      existing_resumed = Array(metadata["resumed_jobs"]).select { |row| row.is_a?(Hash) }
      metadata["resumed_jobs"] = (existing_resumed + resumed).last(60)
      metadata["pending_resume_jobs"] = still_pending
      metadata["resume_failures"] = failures.first(20) if failures.any?
      metadata["last_resume_attempt_at"] = Time.current.iso8601(3)
      action_log.update!(metadata: metadata)
    end

    {
      pending_count: pending.length,
      resumed_count: resumed.length,
      failed_count: failures.length,
      failures: failures.first(20),
      resumed_job_ids: resumed.map { |row| row["resumed_job_id"] }.compact.first(30)
    }
  rescue StandardError => e
    {
      pending_count: 0,
      resumed_count: 0,
      failed_count: 1,
      failures: [
        {
          "error_class" => e.class.name,
          "error_message" => e.message.to_s
        }
      ]
    }
  end

  def dedupe_resume_jobs(rows:)
    seen = Set.new
    Array(rows).each_with_object([]) do |row, out|
      next unless row.is_a?(Hash)

      fingerprint = row["fingerprint"].to_s
      if fingerprint.blank?
        fingerprint = Digest::SHA256.hexdigest("#{row['job_class']}:#{row['job_kwargs']}")
      end
      next if seen.include?(fingerprint)

      seen << fingerprint
      out << row.merge("fingerprint" => fingerprint)
    end
  end
end
