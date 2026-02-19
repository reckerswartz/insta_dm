require "rails_helper"

RSpec.describe "Background Job Execution Diagnostics", :diagnostic do
  include ActiveJob::TestHelper

  it "executes lightweight queue health checks through ActiveJob" do
    allow(Ops::QueueHealth).to receive(:check!).and_return(true)

    perform_enqueued_jobs do
      CheckQueueHealthJob.perform_later
    end

    expect(Ops::QueueHealth).to have_received(:check!)
  end

  it "keeps enqueue+perform semantics deterministic for diagnostics jobs" do
    stub_const("Diagnostics::InlineProbeJob", Class.new(ApplicationJob) do
      queue_as :default
      class_attribute :performed_values, default: []

      def perform(payload = {})
        self.class.performed_values += [payload.fetch("value", "ok")]
      end
    end)

    perform_enqueued_jobs do
      Diagnostics::InlineProbeJob.perform_later("value" => "done")
    end

    expect(Diagnostics::InlineProbeJob.performed_values).to include("done")
  end
end
