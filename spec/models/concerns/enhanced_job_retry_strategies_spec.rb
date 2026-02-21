require "rails_helper"

RSpec.describe EnhancedJobRetryStrategies, type: :model do
  let(:test_job_class) do
    Class.new(ApplicationJob) do
      def self.name
        "TestRetryJob"
      end
    end
  end

  describe ".calculate_retry_delay" do
    it "returns jittered network delay within expected bounds" do
      delay = test_job_class.calculate_retry_delay(1, :network_errors)
      expect(delay).to be_between(4.5, 5.5)
    end

    it "returns jittered ai-service delay within expected bounds" do
      delay = test_job_class.calculate_retry_delay(1, :ai_service_errors)
      expect(delay).to be_between(21.0, 39.0)
    end

    it "applies jitter" do
      delays = Array.new(8) { test_job_class.calculate_retry_delay(3, :network_errors) }
      expect(delays.uniq.length).to be > 1
    end

    it "caps at max interval before jitter" do
      delay = test_job_class.calculate_retry_delay(10, :network_errors)
      expect(delay).to be_between(270.0, 330.0)
    end

    it "falls back to network config for unknown categories" do
      delay = test_job_class.calculate_retry_delay(1, :unknown_error)
      expect(delay).to be_between(4.5, 5.5)
    end
  end

  describe ".categorize_error" do
    it "categorizes known buckets" do
      expect(test_job_class.categorize_error(Net::ReadTimeout.new)).to eq(:network_errors)
      expect(test_job_class.categorize_error(ActiveRecord::ConnectionTimeoutError.new)).to eq(:database_errors)
      expect(test_job_class.categorize_error(Timeout::Error.new)).to eq(:ai_service_errors)
    end

    it "categorizes resource errors by message" do
      expect(test_job_class.categorize_error(StandardError.new("resource capacity exceeded"))).to eq(:resource_errors)
    end
  end

  describe ".should_retry_job?" do
    it "rejects non-retryable and over-attempted errors" do
      expect(test_job_class.should_retry_job?("Test", ActiveRecord::RecordNotFound, 1)).to be(false)
      expect(test_job_class.should_retry_job?("Test", StandardError, 10)).to be(false)
    end

    it "allows retryable errors" do
      expect(test_job_class.should_retry_job?("Test", Net::ReadTimeout, 2)).to be(true)
    end
  end

  describe "instance retry helpers" do
    let(:instance) { test_job_class.new }
    let(:job_like) { double("JobLike", executions: 1, class: double(name: "TestRetryJob")) }

    before do
      allow(instance.class).to receive(:calculate_retry_delay).and_return(0)
      allow(instance).to receive(:sleep)
    end

    it "logs network retries" do
      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.network_retry",
        payload: hash_including(job_class: "TestRetryJob", attempt: 1, error_class: "Net::ReadTimeout")
      )

      instance.send(:handle_network_retry, job_like, Net::ReadTimeout.new("timeout"))
    end

    it "checks database health for database retries" do
      expect(instance).to receive(:check_database_health!)
      allow(Ops::StructuredLogger).to receive(:warn)

      instance.send(:handle_database_retry, job_like, ActiveRecord::ConnectionTimeoutError.new("db"))
    end

    it "checks ai service health for ai retries" do
      expect(instance).to receive(:check_ai_service_health!)
      allow(Ops::StructuredLogger).to receive(:warn)

      instance.send(:handle_ai_service_retry, job_like, Timeout::Error.new("ai"))
    end
  end

  describe "registered handlers" do
    it "registers expected rescue handlers on ApplicationJob" do
      handlers = ApplicationJob.send(:rescue_handlers).map(&:first)

      expect(handlers).to include(
        "Net::ReadTimeout",
        "Net::OpenTimeout",
        "Errno::ECONNRESET",
        "Errno::ECONNREFUSED",
        "ActiveRecord::ConnectionTimeoutError",
        "ActiveRecord::LockWaitTimeout",
        "Timeout::Error"
      )
    end
  end
end
