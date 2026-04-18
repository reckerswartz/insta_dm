namespace :jobs do
  desc "Purge Sidekiq retry/dead/scheduled payloads + cron entries + BackgroundJobExecutionMetric rows whose Active Job class is no longer loadable"
  task purge_unresolvable: :environment do
    require "sidekiq/api"
    require "sidekiq/cron/job"

    def unresolvable_class?(klass)
      return false if klass.blank?

      klass.to_s.constantize
      false
    rescue NameError
      true
    end

    dropped = []
    sets = {
      "Sidekiq::RetrySet"     => Sidekiq::RetrySet.new,
      "Sidekiq::DeadSet"      => Sidekiq::DeadSet.new,
      "Sidekiq::ScheduledSet" => Sidekiq::ScheduledSet.new
    }

    sets.each do |label, set|
      set.each do |job|
        klass = job["wrapped"].presence || job["class"].presence
        if unresolvable_class?(klass)
          dropped << { set: label, class: klass, jid: job["jid"] }
          job.delete
        end
      end
    end

    cron_dropped = []
    Sidekiq::Cron::Job.all.each do |cron_job|
      klass = cron_job.klass.to_s.presence
      if unresolvable_class?(klass)
        cron_dropped << { name: cron_job.name, class: klass, cron: cron_job.cron }
        cron_job.destroy
      end
    end

    # `BackgroundJobExecutionMetric` accumulates one row per
    # attempted-but-failed Active Job dispatch, including the very high
    # queue-wait-ms numbers logged for deprovisioned-class payloads before
    # Ops::OrphanedJobClassMiddleware landed. Those rows do not poison the
    # QueueProcessingEstimator (which filters to status='completed'), but
    # they bloat the table and skew ad-hoc analytics.
    metric_dropped = 0
    metric_breakdown = Hash.new(0)
    unresolvable_metric_classes = BackgroundJobExecutionMetric
      .where.not(job_class: nil)
      .distinct
      .pluck(:job_class)
      .select { |klass| unresolvable_class?(klass) }

    if unresolvable_metric_classes.any?
      metric_breakdown = BackgroundJobExecutionMetric
        .where(job_class: unresolvable_metric_classes)
        .group(:job_class).count
      metric_dropped = BackgroundJobExecutionMetric
        .where(job_class: unresolvable_metric_classes)
        .delete_all
    end

    if dropped.empty? && cron_dropped.empty? && metric_dropped.zero?
      puts "No orphaned payloads, cron entries, or metric rows found."
      next
    end

    unless dropped.empty?
      puts "Dropped #{dropped.size} orphaned Sidekiq payload(s):"
      dropped.group_by { |row| row[:class] }.each do |klass, rows|
        puts "  #{klass}: #{rows.size} payload(s)"
      end
    end

    unless cron_dropped.empty?
      puts "Dropped #{cron_dropped.size} orphaned cron entry(ies):"
      cron_dropped.each { |row| puts "  #{row[:name]} → #{row[:class]} (#{row[:cron]})" }
    end

    if metric_dropped.positive?
      puts "Dropped #{metric_dropped} orphaned BackgroundJobExecutionMetric row(s):"
      metric_breakdown.each { |klass, n| puts "  #{klass}: #{n} row(s)" }
    end

    puts JSON.pretty_generate(
      payloads: dropped,
      cron_entries: cron_dropped,
      execution_metrics: { dropped: metric_dropped, by_class: metric_breakdown }
    )
  end
end
