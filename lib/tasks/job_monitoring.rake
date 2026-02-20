# Background job monitoring and cleanup rake task

namespace :jobs do
  desc "Monitor and clean up problematic background jobs"
  task health_check: :environment do
    require 'sidekiq/api'
    
    puts "=== Background Job Health Check ==="
    puts "Time: #{Time.current}"
    puts
    
    # Check queue sizes
    Sidekiq::Queue.all.each do |queue|
      puts "Queue #{queue.name}: #{queue.size} jobs"
    end
    
    puts
    
    # Check retry set
    retry_set = Sidekiq::RetrySet.new
    puts "Retry set: #{retry_set.size} jobs"
    
    if retry_set.size > 0
      puts "Jobs in retry set:"
      retry_set.each do |job|
        puts "  - #{job.klass}: #{job.item['error_message']}"
      end
    end
    
    puts
    
    # Check dead set
    dead_set = Sidekiq::DeadSet.new
    puts "Dead set: #{dead_set.size} jobs"
    
    if dead_set.size > 0
      puts "Jobs in dead set:"
      dead_set.each do |job|
        puts "  - #{job.klass}: #{job.item['error_message']}"
      end
    end
    
    puts
    puts "=== Health Check Complete ==="
  end
  
  desc "Clean up test/diagnostic jobs from all queues"
  task cleanup_test_jobs: :environment do
    require 'sidekiq/api'
    
    puts "Cleaning up test/diagnostic jobs..."
    
    # Clean from active queues
    Sidekiq::Queue.all.each do |queue|
      original_size = queue.size
      queue.each do |job|
        if job.klass.include?('Diagnostics::') || job.klass.include?('Test') || job.klass.include?('InlineProbe')
          job.delete
        end
      end
      puts "Queue #{queue.name}: removed #{original_size - queue.size} test jobs"
    end
    
    # Clean from retry set
    retry_set = Sidekiq::RetrySet.new
    original_retry_size = retry_set.size
    retry_set.each do |job|
      if job.item['error_message']&.include?('Diagnostics::') || job.klass.include?('InlineProbe')
        job.delete
      end
    end
    puts "Retry set: removed #{original_retry_size - retry_set.size} test jobs"
    
    # Clean from dead set
    dead_set = Sidekiq::DeadSet.new
    original_dead_size = dead_set.size
    dead_set.each do |job|
      if job.klass.include?('Diagnostics::') || job.klass.include?('InlineProbe')
        job.delete
      end
    end
    puts "Dead set: removed #{original_dead_size - dead_set.size} test jobs"
    
    puts "Cleanup complete!"
  end
  
  desc "Monitor story sync job failures"
  task monitor_story_failures: :environment do
    puts "Monitoring recent story sync failures..."
    
    # Get recent failure events from the last hour
    recent_failures = InstagramProfileEvent.where(
      kind: 'story_sync_failed',
      occurred_at: 1.hour.ago..Time.current
    ).order(occurred_at: :desc).limit(20)
    
    if recent_failures.any?
      puts "Found #{recent_failures.count} recent story sync failures:"
      recent_failures.each do |event|
        metadata = event.metadata || {}
        puts "  - #{event.occurred_at}: #{metadata['reason']} (#{metadata['story_ref']})"
      end
    else
      puts "No recent story sync failures found."
    end
  end
end
