namespace :jobs do
  desc "Purge Sidekiq retry/dead/scheduled payloads whose Active Job class is no longer loadable"
  task purge_unresolvable: :environment do
    require "sidekiq/api"

    dropped = []
    sets = {
      "Sidekiq::RetrySet"     => Sidekiq::RetrySet.new,
      "Sidekiq::DeadSet"      => Sidekiq::DeadSet.new,
      "Sidekiq::ScheduledSet" => Sidekiq::ScheduledSet.new
    }

    sets.each do |label, set|
      set.each do |job|
        klass = job["wrapped"].presence || job["class"].presence
        next if klass.blank?

        begin
          klass.constantize
        rescue NameError
          dropped << { set: label, class: klass, jid: job["jid"] }
          job.delete
        end
      end
    end

    if dropped.empty?
      puts "No orphaned payloads found in Sidekiq retry/dead/scheduled sets."
    else
      puts "Dropped #{dropped.size} orphaned payload(s):"
      dropped.group_by { |row| row[:class] }.each do |klass, rows|
        puts "  #{klass}: #{rows.size} payload(s)"
      end
      puts JSON.pretty_generate(dropped)
    end
  end
end
