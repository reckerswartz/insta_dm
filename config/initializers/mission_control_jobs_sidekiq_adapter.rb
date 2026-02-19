if defined?(MissionControl::Jobs) && defined?(ActiveJob::QueueAdapters::SidekiqAdapter)
  require "sidekiq/api"

  module ActiveJob
    module QueueAdapters
      module SidekiqExt
        include MissionControl::Jobs::Adapter

        def queues
          Sidekiq::Queue.all.map do |queue|
            { name: queue.name, size: queue.size, active: !queue.paused? }
          end
        end

        def queue_size(queue_name)
          Sidekiq::Queue.new(queue_name).size
        end

        def clear_queue(queue_name)
          Sidekiq::Queue.new(queue_name).clear
        end

        def supports_queue_pausing?
          false
        end

        def queue_paused?(_queue_name)
          false
        end

        def supported_job_statuses
          [ :pending, :failed ]
        end

        def supported_job_filters(jobs_relation)
          if jobs_relation.pending? || jobs_relation.failed?
            [ :queue_name, :job_class_name ]
          else
            []
          end
        end

        def jobs_count(jobs_relation)
          return 0 unless jobs_relation.pending? || jobs_relation.failed?

          SidekiqJobs.new(jobs_relation).count
        end

        def fetch_jobs(jobs_relation)
          return [] unless jobs_relation.pending? || jobs_relation.failed?

          SidekiqJobs.new(jobs_relation).all
        end

        def retry_all_jobs(jobs_relation)
          return unless jobs_relation.failed?

          SidekiqJobs.new(jobs_relation).retry_all
        end

        def retry_job(job, jobs_relation)
          return unless jobs_relation.failed?

          SidekiqJobs.new(jobs_relation).retry(job.job_id)
        end

        def discard_all_jobs(jobs_relation)
          if jobs_relation.pending? || jobs_relation.failed?
            SidekiqJobs.new(jobs_relation).discard_all
          end
        end

        def discard_job(job, jobs_relation)
          if jobs_relation.pending? || jobs_relation.failed?
            SidekiqJobs.new(jobs_relation).discard(job.job_id)
          else
            SidekiqJobs.new(jobs_relation.pending).discard(job.job_id) ||
              SidekiqJobs.new(jobs_relation.failed).discard(job.job_id)
          end
        end

        def find_job(job_id, jobs_relation = nil)
          return find_job_across_statuses(job_id) if jobs_relation.nil?

          if jobs_relation.pending? || jobs_relation.failed?
            SidekiqJobs.new(jobs_relation).find(job_id)
          else
            SidekiqJobs.new(jobs_relation.pending).find(job_id) ||
              SidekiqJobs.new(jobs_relation.failed).find(job_id)
          end
        end

        private
          def find_job_across_statuses(job_id)
            SidekiqJobs.new(ActiveJob.jobs.pending).find(job_id) ||
              SidekiqJobs.new(ActiveJob.jobs.failed).find(job_id)
          end

          class SidekiqJobs
            def initialize(jobs_relation)
              @jobs_relation = jobs_relation
            end

            def count
              entries(status_filtered: true).size
            end

            def all
              paginated_entries = apply_pagination(entries(status_filtered: true))
              paginated_entries.each_with_index.filter_map do |entry, index|
                build_job(entry, index)
              end
            end

            def retry_all
              entries(status_filtered: true).each(&:retry)
            end

            def retry(job_id)
              find_entry(job_id)&.retry
            end

            def discard_all
              entries(status_filtered: true).each(&:delete)
            end

            def discard(job_id)
              find_entry(job_id)&.delete
            end

            def find(job_id)
              entry = find_entry(job_id)
              return nil unless entry

              build_job(entry, 0)
            end

            private
              attr_reader :jobs_relation

              def entries(status_filtered:)
                selected_entries = status_entries_for_relation
                selected_entries = select_native_filters(selected_entries) if status_filtered
                selected_entries
              end

              def status_entries_for_relation
                if jobs_relation.pending?
                  pending_entries
                elsif jobs_relation.failed?
                  failed_entries
                else
                  []
                end
              end

              def pending_entries
                if jobs_relation.queue_name.present?
                  Sidekiq::Queue.new(jobs_relation.queue_name).to_a
                else
                  Sidekiq::Queue.all.flat_map(&:to_a)
                end
              end

              def failed_entries
                entries = Sidekiq::RetrySet.new.to_a + Sidekiq::DeadSet.new.to_a
                entries.sort_by { |entry| -(entry.at&.to_f || 0.0) }
              end

              def select_native_filters(selected_entries)
                selected_entries.select do |entry|
                  matches_queue_name?(entry) && matches_job_class_name?(entry)
                end
              end

              def matches_queue_name?(entry)
                return true if jobs_relation.queue_name.blank?

                entry.queue.to_s == jobs_relation.queue_name.to_s
              end

              def matches_job_class_name?(entry)
                return true if jobs_relation.job_class_name.blank?

                serialized_job_data(entry)&.dig("job_class") == jobs_relation.job_class_name
              end

              def apply_pagination(selected_entries)
                paginated_entries = selected_entries
                offset = jobs_relation.offset_value.to_i

                paginated_entries = paginated_entries.drop(offset) if offset.positive?
                paginated_entries = paginated_entries.first(jobs_relation.limit_value.to_i) if jobs_relation.limit_value_provided?
                paginated_entries
              end

              def find_entry(job_id)
                normalized_job_id = job_id.to_s
                entries(status_filtered: true).find do |entry|
                  entry_job_id(entry) == normalized_job_id
                end
              end

              def entry_job_id(entry)
                serialized_job_data(entry)&.dig("job_id")&.to_s || entry.jid.to_s
              end

              def build_job(entry, index)
                serialized_job = serialized_job_data(entry)
                return nil unless serialized_job

                status = jobs_relation.status&.to_sym
                ActiveJob::JobProxy.new(serialized_job).tap do |job|
                  job.status = status
                  job.position = jobs_relation.offset_value.to_i + index
                  job.raw_data = entry.item
                  job.provider_job_id = entry.jid if job.respond_to?(:provider_job_id=)
                  job.enqueued_at = enqueued_at_for(entry, serialized_job)

                  next unless status == :failed

                  job.failed_at = failed_at_for(entry)
                  job.last_execution_error = execution_error_for(entry)
                end
              end

              def serialized_job_data(entry)
                args = entry.item["args"]
                payload = args.is_a?(Array) ? args.first : nil
                return payload.deep_dup if payload.is_a?(Hash) && payload["job_class"].present?

                nil
              end

              def enqueued_at_for(entry, serialized_job)
                parse_timestamp(serialized_job["enqueued_at"]) ||
                  parse_timestamp(entry.item["enqueued_at"]) ||
                  entry.try(:enqueued_at) ||
                  entry.try(:created_at) ||
                  entry.try(:at) ||
                  Time.current
              end

              def failed_at_for(entry)
                parse_timestamp(entry.item["failed_at"]) ||
                  parse_timestamp(entry.item["retried_at"]) ||
                  entry.try(:at) ||
                  Time.current
              end

              def execution_error_for(entry)
                ActiveJob::ExecutionError.new(
                  error_class: entry.item["error_class"] || "StandardError",
                  message: entry.item["error_message"] || "Unknown Sidekiq failure",
                  backtrace: Array(entry.item["error_backtrace"])
                )
              end

              def parse_timestamp(value)
                case value
                when Time
                  value.utc
                when Numeric
                  Time.at(value).utc
                when String
                  return Time.at(value.to_f).utc if value.match?(/\A-?\d+(\.\d+)?\z/)

                  Time.zone.parse(value)&.utc
                else
                  nil
                end
              rescue ArgumentError, TypeError
                nil
              end
          end
      end
    end
  end

  unless ActiveJob::QueueAdapters::SidekiqAdapter < ActiveJob::QueueAdapters::SidekiqExt
    ActiveJob::QueueAdapters::SidekiqAdapter.prepend(ActiveJob::QueueAdapters::SidekiqExt)
  end
end
