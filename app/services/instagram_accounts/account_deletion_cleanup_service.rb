require "set"

module InstagramAccounts
  class AccountDeletionCleanupService
    class CleanupError < StandardError; end

    RUNNING_JOB_WAIT_TIMEOUT = 15.seconds
    RUNNING_JOB_WAIT_INTERVAL = 0.5.seconds

    def initialize(account:)
      @account = account
    end

    def call
      clear_account_jobs!
      purge_account_storage!
      delete_account_observability_rows!
      true
    rescue CleanupError
      raise
    rescue StandardError => e
      raise CleanupError, "Account cleanup failed: #{e.class}: #{e.message}"
    end

    private

    attr_reader :account

    def clear_account_jobs!
      return unless sidekiq_backend?

      require "sidekiq/api"

      removed = 0
      Sidekiq::Queue.all.each do |queue|
        removed += remove_entries_for_account!(entries: queue, reason: "account_deleted")
      end
      removed += remove_entries_for_account!(entries: Sidekiq::ScheduledSet.new, reason: "account_deleted")
      removed += remove_entries_for_account!(entries: Sidekiq::RetrySet.new, reason: "account_deleted")
      removed += remove_entries_for_account!(entries: Sidekiq::DeadSet.new, reason: "account_deleted")

      wait_for_running_jobs_to_clear!

      Ops::StructuredLogger.info(
        event: "account_delete.queue_cleanup",
        payload: {
          instagram_account_id: account.id,
          removed_jobs: removed
        }
      )
    end

    def remove_entries_for_account!(entries:, reason:)
      removed = 0
      entries.each do |entry|
        next unless entry_targets_account?(entry)

        Ops::BackgroundJobLifecycleRecorder.record_sidekiq_removal(entry: entry, reason: reason)
        entry.delete
        removed += 1
      rescue StandardError
        next
      end
      removed
    end

    def wait_for_running_jobs_to_clear!
      deadline = Time.current + RUNNING_JOB_WAIT_TIMEOUT
      loop do
        count = running_account_job_count
        return if count.zero?

        if Time.current >= deadline
          raise CleanupError, "Cannot delete account while #{count} job(s) are still running for this account."
        end

        sleep(RUNNING_JOB_WAIT_INTERVAL)
      end
    end

    def running_account_job_count
      return 0 unless defined?(Sidekiq::Workers)

      count = 0
      Sidekiq::Workers.new.each do |_process_id, _thread_id, work|
        payload = work.is_a?(Hash) ? (work["payload"] || work[:payload]) : nil
        count += 1 if sidekiq_item_targets_account?(payload)
      end
      count
    rescue StandardError
      0
    end

    def purge_account_storage!
      ids = account_attachment_ids
      return if ids.empty?

      # ActiveStorage::Attachment#purge uses `delete` internally, which bypasses
      # dependent callbacks. Remove ingestion rows first to avoid FK-protected blobs.
      ActiveStorageIngestion.where(active_storage_attachment_id: ids).delete_all

      attachment_scope = ActiveStorage::Attachment.where(id: ids)
      candidate_blob_ids = attachment_scope.pluck(:blob_id).uniq

      attachment_scope.find_each do |attachment|
        attachment.purge
      rescue StandardError => e
        raise CleanupError, "Failed to purge attachment ##{attachment.id}: #{e.class}: #{e.message}"
      end

      ActiveStorage::Blob.where(id: candidate_blob_ids)
        .left_outer_joins(:attachments)
        .where(active_storage_attachments: { id: nil })
        .find_each(&:purge)
    end

    def account_attachment_ids
      profile_ids = instagram_profile_ids
      profile_post_ids = instagram_profile_post_ids
      event_ids = InstagramProfileEvent.where(instagram_profile_id: profile_ids).select(:id)
      story_ids = InstagramStory.where(instagram_account_id: account.id).select(:id)
      post_ids = InstagramPost.where(instagram_account_id: account.id).select(:id)

      ingestion_attachment_ids = ActiveStorageIngestion
        .where(instagram_account_id: account.id)
        .pluck(:active_storage_attachment_id)

      fallback_ids = []
      fallback_ids.concat(
        ActiveStorage::Attachment.where(record_type: "InstagramProfile", record_id: profile_ids).pluck(:id)
      )
      fallback_ids.concat(
        ActiveStorage::Attachment.where(record_type: "InstagramProfilePost", record_id: profile_post_ids).pluck(:id)
      )
      fallback_ids.concat(
        ActiveStorage::Attachment.where(record_type: "InstagramProfileEvent", record_id: event_ids).pluck(:id)
      )
      fallback_ids.concat(
        ActiveStorage::Attachment.where(record_type: "InstagramStory", record_id: story_ids).pluck(:id)
      )
      fallback_ids.concat(
        ActiveStorage::Attachment.where(record_type: "InstagramPost", record_id: post_ids).pluck(:id)
      )

      (ingestion_attachment_ids + fallback_ids).uniq
    end

    def delete_account_observability_rows!
      profile_ids = instagram_profile_ids
      profile_post_ids = instagram_profile_post_ids

      AppIssue.where(instagram_account_id: account.id).or(AppIssue.where(instagram_profile_id: profile_ids)).delete_all
      BackgroundJobFailure.where(instagram_account_id: account.id).or(BackgroundJobFailure.where(instagram_profile_id: profile_ids)).delete_all
      BackgroundJobExecutionMetric.where(instagram_account_id: account.id)
        .or(BackgroundJobExecutionMetric.where(instagram_profile_id: profile_ids))
        .or(BackgroundJobExecutionMetric.where(instagram_profile_post_id: profile_post_ids))
        .delete_all
      ServiceOutputAudit.where(instagram_account_id: account.id)
        .or(ServiceOutputAudit.where(instagram_profile_id: profile_ids))
        .or(ServiceOutputAudit.where(instagram_profile_post_id: profile_post_ids))
        .delete_all
      BackgroundJobLifecycle.where(instagram_account_id: account.id)
        .or(BackgroundJobLifecycle.where(instagram_profile_id: profile_ids))
        .or(BackgroundJobLifecycle.where(instagram_profile_post_id: profile_post_ids))
        .delete_all
      ActiveStorageIngestion.where(instagram_account_id: account.id)
        .or(ActiveStorageIngestion.where(instagram_profile_id: profile_ids))
        .delete_all
    end

    def entry_targets_account?(entry)
      item = entry.respond_to?(:item) ? entry.item : nil
      sidekiq_item_targets_account?(item)
    rescue StandardError
      false
    end

    def sidekiq_item_targets_account?(item)
      context = Jobs::ContextExtractor.from_sidekiq_item(item)
      account_id = context[:instagram_account_id].to_i
      profile_id = context[:instagram_profile_id].to_i
      profile_post_id = context[:instagram_profile_post_id].to_i

      return true if account_id.positive? && account_id == account.id
      return true if profile_id.positive? && instagram_profile_id_set.include?(profile_id)
      return true if profile_post_id.positive? && instagram_profile_post_id_set.include?(profile_post_id)

      false
    rescue StandardError
      false
    end

    def sidekiq_backend?
      Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
    rescue StandardError
      false
    end

    def instagram_profile_ids
      @instagram_profile_ids ||= account.instagram_profiles.select(:id)
    end

    def instagram_profile_post_ids
      @instagram_profile_post_ids ||= account.instagram_profile_posts.select(:id)
    end

    def instagram_profile_id_set
      @instagram_profile_id_set ||= instagram_profile_ids.pluck(:id).to_set
    end

    def instagram_profile_post_id_set
      @instagram_profile_post_id_set ||= instagram_profile_post_ids.pluck(:id).to_set
    end
  end
end
