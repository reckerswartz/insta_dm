require "rails_helper"
require "securerandom"

# Phase 13 F-admin-failures-I3: deleted_record classification on top of the
# existing `discard_on ActiveRecord::RecordNotFound` handler.
RSpec.describe "ApplicationJob deleted_record classification", type: :job do
  # A tiny job class that always raises ActiveRecord::RecordNotFound inside
  # perform, simulating a real job whose argument references a since-deleted
  # record (e.g. a profile id that was destroyed by an account cleanup).
  class RecordNotFoundProbeJob < ApplicationJob
    queue_as :default

    def perform(profile_id:)
      raise ActiveRecord::RecordNotFound, "Couldn't find InstagramProfile with 'id'=#{profile_id}"
    end
  end

  it "records a deleted_record BackgroundJobFailure row when perform raises RecordNotFound" do
    profile_id = 99_999_999

    expect do
      RecordNotFoundProbeJob.perform_now(profile_id: profile_id)
    end.to change { BackgroundJobFailure.where(failure_kind: "deleted_record").count }.by(1)

    row = BackgroundJobFailure.where(failure_kind: "deleted_record").order(:id).last
    expect(row.job_class).to eq("RecordNotFoundProbeJob")
    expect(row.error_class).to eq("ActiveRecord::RecordNotFound")
    expect(row.error_message).to include(profile_id.to_s)
    expect(row.retryable).to eq(false)
    expect(row.queue_name).to eq("default")
  end

  it "marks deleted_record failures as retryable_now? => false" do
    failure = BackgroundJobFailure.create!(
      job_class: "RecordNotFoundProbeJob",
      queue_name: "default",
      failure_kind: "deleted_record",
      retryable: true,                  # deliberately true to prove predicate wins
      error_class: "ActiveRecord::RecordNotFound",
      error_message: "Couldn't find InstagramProfile with 'id'=42",
      active_job_id: SecureRandom.uuid,
      occurred_at: Time.current
    )

    expect(failure.deleted_record_failure?).to be true
    expect(failure.retryable_now?).to be false
  end
end
