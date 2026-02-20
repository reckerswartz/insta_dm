RSpec.configure do |config|
  config.include ActiveJob::TestHelper

  config.before(:suite) do
    ActiveJob::Base.queue_adapter = :test
  end

  config.before(:each) do
    clear_enqueued_jobs
    clear_performed_jobs
  end
end
