namespace :jobs do
  desc "Purge Sidekiq retry/dead/scheduled payloads + cron entries whose Active Job class is no longer loadable"
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

    if dropped.empty? && cron_dropped.empty?
      puts "No orphaned payloads or cron entries found."
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

    puts JSON.pretty_generate(payloads: dropped, cron_entries: cron_dropped)
  end
end
