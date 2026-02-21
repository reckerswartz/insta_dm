require "rails_helper"

RSpec.describe JobHealthMonitorJob, type: :job do
  describe "#perform" do
    let(:job) { described_class.new }

    before do
      allow(job).to receive(:check_queue_health)
      allow(job).to receive(:check_failure_patterns)
      allow(job).to receive(:check_resource_utilization)
      allow(job).to receive(:generate_health_report)
    end

    it "calls all health check methods" do
      expect(job).to receive(:check_queue_health)
      expect(job).to receive(:check_failure_patterns)
      expect(job).to receive(:check_resource_utilization)
      expect(job).to receive(:generate_health_report)

      job.perform
    end
  end

  describe "#check_queue_health" do
    let(:job) { described_class.new }
    let(:queue) { double("Queue", name: "test_queue", size: queue_size) }
    let(:queue_size) { 150 }
    let(:retry_set) { double("RetrySet", size: retry_size) }
    let(:retry_size) { 0 }

    before do
      allow(Sidekiq::Queue).to receive(:all).and_return([queue])
      allow(Sidekiq::RetrySet).to receive(:new).and_return(retry_set)
    end

    it "logs warning for congested queues" do
      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.queue_congestion",
        payload: hash_including(queue_name: "test_queue", queue_size: 150, severity: "warning")
      )

      job.send(:check_queue_health)
    end

    context "when queue is severely congested" do
      let(:queue_size) { 600 }

      it "logs critical warning" do
        expect(Ops::StructuredLogger).to receive(:warn).with(
          event: "job.queue_congestion",
          payload: hash_including(queue_name: "test_queue", queue_size: 600, severity: "critical")
        )

        job.send(:check_queue_health)
      end
    end

    context "when retry set is large" do
      let(:queue_size) { 0 }
      let(:retry_size) { 75 }

      it "logs retry set warning" do
        expect(Ops::StructuredLogger).to receive(:warn).with(
          event: "job.retry_set_large",
          payload: hash_including(retry_set_size: 75, severity: "warning")
        )

        job.send(:check_queue_health)
      end
    end
  end

  describe "#check_failure_patterns" do
    let(:job) { described_class.new }
    let(:recent_failures) { double("RecentFailures") }
    let(:grouped_relation) { double("GroupedFailures", count: grouped_counts) }
    let(:grouped_counts) { {} }

    before do
      allow(BackgroundJobFailure).to receive(:where).with("occurred_at > ?", kind_of(Time)).and_return(recent_failures)
      allow(recent_failures).to receive(:group).with(:error_class).and_return(grouped_relation)

      auth_failures = double("AuthFailures", count: 0)
      timeout_failures = double("TimeoutFailures", count: 0)
      resource_failures = double("ResourceFailures", count: 0)
      allow(recent_failures).to receive(:where).with(error_class: "Instagram::AuthenticationRequiredError").and_return(auth_failures)
      allow(recent_failures).to receive(:where).with("error_class ILIKE ?", "%Timeout%").and_return(timeout_failures)
      allow(recent_failures).to receive(:where).with("error_message ILIKE ?", "%resource%").and_return(resource_failures)
      allow(auth_failures).to receive(:group).with(:instagram_account_id).and_return({})
    end

    context "with error spikes" do
      let(:grouped_counts) { { "StandardError" => 15 } }

      it "logs warning" do
        expect(Ops::StructuredLogger).to receive(:warn).with(
          event: "job.error_spike",
          payload: hash_including(error_class: "StandardError", count: 15, severity: "warning")
        )

        job.send(:check_failure_patterns)
      end
    end

    context "with severe error spikes" do
      let(:grouped_counts) { { "StandardError" => 60 } }

      it "logs critical warning" do
        expect(Ops::StructuredLogger).to receive(:warn).with(
          event: "job.error_spike",
          payload: hash_including(error_class: "StandardError", count: 60, severity: "critical")
        )

        job.send(:check_failure_patterns)
      end
    end

    it "checks authentication failures" do
      auth_failures = double("AuthFailures", count: 8)
      auth_grouped = double("AuthGrouped", count: { 123 => 5 })
      allow(recent_failures).to receive(:where).with(error_class: "Instagram::AuthenticationRequiredError").and_return(auth_failures)
      allow(auth_failures).to receive(:group).with(:instagram_account_id).and_return(auth_grouped)

      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.account_authentication_issues",
        payload: hash_including(instagram_account_id: 123, failure_count: 5, severity: "warning")
      )

      job.send(:check_failure_patterns)
    end

    it "checks timeout failures" do
      timeout_failures = double("TimeoutFailures", count: 8)
      allow(recent_failures).to receive(:where).with("error_class ILIKE ?", "%Timeout%").and_return(timeout_failures)

      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.timeout_spike",
        payload: hash_including(timeout_count: 8, severity: "warning")
      )

      job.send(:check_failure_patterns)
    end

    it "checks resource constraint failures" do
      resource_failures = double("ResourceFailures", count: 5)
      allow(recent_failures).to receive(:where).with("error_message ILIKE ?", "%resource%").and_return(resource_failures)

      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.resource_constraints",
        payload: hash_including(resource_error_count: 5, severity: "warning")
      )

      job.send(:check_failure_patterns)
    end
  end

  describe "#check_resource_utilization" do
    let(:job) { described_class.new }
    let(:process_set) { double("ProcessSet", size: 0) }
    let(:workers) { double("Workers", size: 60) }

    before do
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(process_set)
      allow(Sidekiq::Workers).to receive(:new).and_return(workers)
    end

    it "logs critical error when no Sidekiq processes are running" do
      expect(Ops::StructuredLogger).to receive(:error).with(
        event: "job.no_sidekiq_processes",
        payload: hash_including(severity: "critical")
      )

      job.send(:check_resource_utilization)
    end

    it "logs high worker utilization" do
      allow(process_set).to receive(:size).and_return(2)

      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.high_worker_utilization",
        payload: hash_including(busy_workers: 60, severity: "warning")
      )

      job.send(:check_resource_utilization)
    end
  end

  describe "#collect_failure_metrics" do
    let(:job) { described_class.new }
    let(:recent_failures) { double("RecentFailures") }
    let(:grouped_relation) { double("GroupedFailures", count: { "StandardError" => 10, "TimeoutError" => 5 }) }

    before do
      allow(BackgroundJobFailure).to receive(:where).with("occurred_at > ?", kind_of(Time)).and_return(recent_failures)
      allow(recent_failures).to receive(:count).and_return(25)
      allow(recent_failures).to receive(:distinct).and_return(double("Distinct", count: 5))
      allow(recent_failures).to receive(:group).with(:error_class).and_return(grouped_relation)
      allow(recent_failures).to receive(:where).with(error_class: "Instagram::AuthenticationRequiredError").and_return(double(count: 8))
      allow(recent_failures).to receive(:where).with("error_class ILIKE ?", "%Timeout%").and_return(double(count: 5))
    end

    it "collects failure metrics" do
      metrics = job.send(:collect_failure_metrics)

      expect(metrics).to include(
        total_failures: 25,
        unique_error_classes: 5,
        top_error_class: "StandardError",
        authentication_failures: 8,
        timeout_failures: 5
      )
    end
  end

  describe "#generate_recommendations" do
    let(:job) { described_class.new }

    before do
      allow(job).to receive(:collect_queue_metrics).and_return({ congested_queues: 2 })
      allow(job).to receive(:collect_failure_metrics).and_return({ authentication_failures: 12, timeout_failures: 8 })
      allow(job).to receive(:collect_resource_metrics).and_return({ active_processes: 2, retry_set_size: 120 })
    end

    it "includes recommendations for observed issues" do
      recommendations = job.send(:generate_recommendations)

      expect(recommendations).to include("Consider increasing worker count for congested queues")
      expect(recommendations).to include("Review Instagram account authentication for multiple failing accounts")
      expect(recommendations).to include("Investigate timeout issues - may need to increase timeouts or fix slow operations")
      expect(recommendations).to include("Large retry set detected - consider manual intervention for stuck jobs")
    end

    it "includes critical recommendation when no processes are active" do
      allow(job).to receive(:collect_resource_metrics).and_return({ active_processes: 0, retry_set_size: 0 })

      recommendations = job.send(:generate_recommendations)

      expect(recommendations).to include("CRITICAL: No Sidekiq processes running - restart Sidekiq immediately")
    end
  end
end
