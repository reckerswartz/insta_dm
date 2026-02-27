require "rails_helper"
require "securerandom"

RSpec.describe Ops::BackgroundJobLifecycleRecorder do
  describe ".record_transition" do
    it "persists lifecycle status changes for the same job id" do
      account = InstagramAccount.create!(username: "lifecycle_account_#{SecureRandom.hex(4)}")
      profile = account.instagram_profiles.create!(username: "lifecycle_profile_#{SecureRandom.hex(4)}")
      active_job_id = SecureRandom.uuid

      queued_at = 4.minutes.ago
      running_at = 3.minutes.ago
      completed_at = 2.minutes.ago

      expect do
        described_class.record_transition(
          payload: {
            status: "queued",
            active_job_id: active_job_id,
            provider_job_id: "jid_#{SecureRandom.hex(4)}",
            job_class: "SyncInstagramProfileStoriesJob",
            queue_name: "story_processing",
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            transition_at: queued_at,
            metadata: { phase: "enqueue" }
          }
        )
      end.to change(BackgroundJobLifecycle, :count).by(1)

      described_class.record_transition(
        payload: {
          status: "running",
          active_job_id: active_job_id,
          job_class: "SyncInstagramProfileStoriesJob",
          queue_name: "story_processing",
          transition_at: running_at
        }
      )
      described_class.record_transition(
        payload: {
          status: "completed",
          active_job_id: active_job_id,
          job_class: "SyncInstagramProfileStoriesJob",
          queue_name: "story_processing",
          transition_at: completed_at,
          metadata: { phase: "finish" }
        }
      )

      lifecycle = BackgroundJobLifecycle.find_by!(active_job_id: active_job_id)
      expect(lifecycle.status).to eq("completed")
      expect(lifecycle.instagram_account_id).to eq(account.id)
      expect(lifecycle.instagram_profile_id).to eq(profile.id)
      expect(lifecycle.related_model_type).to eq("InstagramProfile")
      expect(lifecycle.related_model_id).to eq(profile.id)
      expect(lifecycle.queued_at.to_i).to eq(queued_at.to_i)
      expect(lifecycle.started_at.to_i).to eq(running_at.to_i)
      expect(lifecycle.completed_at.to_i).to eq(completed_at.to_i)
      expect(lifecycle.metadata).to include("phase" => "finish")
    end
  end

  describe ".record_sidekiq_removal" do
    it "marks a queued active job as removed with reason metadata" do
      account = InstagramAccount.create!(username: "remove_account_#{SecureRandom.hex(4)}")
      profile = account.instagram_profiles.create!(username: "remove_profile_#{SecureRandom.hex(4)}")
      active_job_id = SecureRandom.uuid

      item = {
        "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        "jid" => "jid_#{SecureRandom.hex(4)}",
        "queue" => "story_processing",
        "args" => [
          {
            "job_class" => "SyncInstagramProfileStoriesJob",
            "job_id" => active_job_id,
            "queue_name" => "story_processing",
            "arguments" => [
              {
                "instagram_account_id" => account.id,
                "instagram_profile_id" => profile.id,
                "story_id" => "story_123"
              }
            ]
          }
        ]
      }
      entry = Struct.new(:item, :queue).new(item, "story_processing")

      described_class.record_sidekiq_removal(entry: entry, reason: "manual_discard")

      lifecycle = BackgroundJobLifecycle.find_by!(active_job_id: active_job_id)
      expect(lifecycle.status).to eq("removed")
      expect(lifecycle.removed_at).to be_present
      expect(lifecycle.story_id).to eq("story_123")
      expect(lifecycle.metadata).to include("removal_reason" => "manual_discard")
      expect(lifecycle.instagram_account_id).to eq(account.id)
      expect(lifecycle.instagram_profile_id).to eq(profile.id)
    end
  end
end
