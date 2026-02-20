module Admin
  module BackgroundJobs
    class JobDetailsBuilder
      def call(row:, action_log:, failure:, direct_ingestions:, direct_llm_events:, direct_api_calls:)
        window = inferred_time_window(row: row, action_log: action_log, failure: failure)
        api_calls = direct_api_calls.presence || fallback_api_calls(row: row, window: window)
        ingestions = direct_ingestions.presence || fallback_ingestions(row: row, window: window)
        llm_events = direct_llm_events.presence || fallback_llm_events(row: row, window: window)
        ai_analyses = related_ai_analyses(row: row, action_log: action_log, window: window)
        story_rows = related_story_rows(row: row, window: window)

        {
          processing_steps: build_processing_steps(
            row: row,
            action_log: action_log,
            failure: failure,
            api_calls: api_calls,
            ingestions: ingestions,
            llm_events: llm_events,
            ai_analyses: ai_analyses,
            story_rows: story_rows
          ),
          final_output: build_final_output(row: row, action_log: action_log, failure: failure),
          api_responses: api_calls.first(8).map { |api_call| serialize_api_call(api_call) },
          technical_data: build_technical_data(
            action_log: action_log,
            llm_events: llm_events,
            ai_analyses: ai_analyses,
            story_rows: story_rows
          ),
          blobs: ingestions.first(10).map { |ingestion| serialize_ingestion(ingestion) }
        }
      rescue StandardError
        fallback(row: row)
      end

      def fallback(row:)
        {
          processing_steps: [ "No detailed processing records were linked to this job yet." ],
          final_output: {
            status: row[:status].to_s,
            summary: row[:error_message].to_s.presence || "No final output captured yet."
          }.compact,
          api_responses: [],
          technical_data: [],
          blobs: []
        }
      end

      private

      def inferred_time_window(row:, action_log:, failure:)
        started_candidates = [
          action_log&.started_at,
          action_log&.occurred_at,
          row[:created_at],
          failure&.occurred_at
        ].compact
        ended_candidates = [
          action_log&.finished_at,
          failure&.occurred_at,
          row[:created_at]
        ].compact
        return nil if started_candidates.empty? && ended_candidates.empty?

        started_at = (started_candidates.min || ended_candidates.min) - 20.minutes
        ended_at = (ended_candidates.max || started_at + 2.hours) + 20.minutes
        started_at..ended_at
      rescue StandardError
        nil
      end

      def fallback_api_calls(row:, window:)
        account_id = row[:instagram_account_id].to_i
        return [] unless account_id.positive?

        scope = AiApiCall.where(instagram_account_id: account_id).order(occurred_at: :desc, id: :desc)
        scope = scope.where(occurred_at: window) if window
        scope.limit(8).to_a
      rescue StandardError
        []
      end

      def fallback_ingestions(row:, window:)
        scope = ActiveStorageIngestion.order(created_at: :desc, id: :desc)
        profile_id = row[:instagram_profile_id].to_i
        account_id = row[:instagram_account_id].to_i
        return [] unless profile_id.positive? || account_id.positive?

        scope = scope.where(instagram_profile_id: profile_id) if profile_id.positive?
        scope = scope.where(instagram_account_id: account_id) if !profile_id.positive? && account_id.positive?
        scope = scope.where(created_at: window) if window
        scope.limit(10).to_a
      rescue StandardError
        []
      end

      def fallback_llm_events(row:, window:)
        profile_id = row[:instagram_profile_id].to_i
        return [] unless profile_id.positive?

        scope = InstagramProfileEvent.where(instagram_profile_id: profile_id).order(updated_at: :desc, id: :desc)
        scope = scope.where(updated_at: window) if window
        scope.limit(6).to_a.select do |event|
          llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
          raw_meta = event.metadata.is_a?(Hash) ? event.metadata : {}
          llm_meta.present? || raw_meta["processing_metadata"].is_a?(Hash) || raw_meta["local_story_intelligence"].is_a?(Hash)
        end
      rescue StandardError
        []
      end

      def related_ai_analyses(row:, action_log:, window:)
        account_id = row[:instagram_account_id].to_i
        return [] unless account_id.positive?

        scope = AiAnalysis.where(instagram_account_id: account_id).order(created_at: :desc, id: :desc)
        scope = scope.where(created_at: window) if window

        profile_id = row[:instagram_profile_id].to_i
        if profile_id.positive?
          scope = scope.where(analyzable_type: "InstagramProfile", analyzable_id: profile_id)
        end

        purpose_hint = purpose_hint_for(row: row, action_log: action_log)
        scope = scope.where(purpose: purpose_hint) if purpose_hint.present?

        scope.limit(6).to_a
      rescue StandardError
        []
      end

      def purpose_hint_for(row:, action_log:)
        klass = row[:class_name].to_s
        action = action_log&.action.to_s
        return "post" if klass.include?("AnalyzeInstagramPostJob") || action == "capture_profile_posts" || action == "analyze_profile_posts"
        return "profile" if klass.include?("AnalyzeInstagramProfileJob") || action == "analyze_profile"

        nil
      end

      def related_story_rows(row:, window:)
        profile_id = row[:instagram_profile_id].to_i
        return [] unless profile_id.positive?

        scope = InstagramStory.where(instagram_profile_id: profile_id).order(updated_at: :desc, id: :desc)
        scope = scope.where(updated_at: window) if window
        scope.limit(6).to_a.select do |story|
          metadata = story.metadata.is_a?(Hash) ? story.metadata : {}
          metadata["processing_metadata"].is_a?(Hash) ||
            metadata["generated_response_suggestions"].present? ||
            metadata["content_understanding"].is_a?(Hash)
        end
      rescue StandardError
        []
      end

      def build_processing_steps(row:, action_log:, failure:, api_calls:, ingestions:, llm_events:, ai_analyses:, story_rows:)
        steps = []
        if row[:created_at].present?
          steps << "Queued in #{row[:queue_name].to_s.presence || '-'} at #{row[:created_at].iso8601}."
        else
          steps << "Queued in #{row[:queue_name].to_s.presence || '-'}."
        end

        if action_log
          steps << "Action log '#{action_log.action}' recorded with status '#{action_log.status}'."
          steps << "Execution started at #{action_log.started_at.iso8601}." if action_log.started_at.present?
          steps << "Execution finished at #{action_log.finished_at.iso8601}." if action_log.finished_at.present?
        end
        steps << "Captured #{api_calls.length} related API call(s)." if api_calls.any?
        steps << "Generated #{ai_analyses.length} AI analysis record(s)." if ai_analyses.any?
        steps << "Updated #{llm_events.length} LLM/story event record(s)." if llm_events.any?
        steps << "Persisted #{story_rows.length} story processing artifact(s)." if story_rows.any?
        steps << "Stored #{ingestions.length} blob/file ingestion record(s)." if ingestions.any?
        if failure
          steps << "Failed at #{failure.occurred_at&.iso8601 || 'unknown time'} with #{failure.error_class}: #{failure.error_message.to_s.byteslice(0, 240)}"
        end

        steps.uniq.first(12)
      end

      def build_final_output(row:, action_log:, failure:)
        {
          status: action_log&.status.to_s.presence || (failure.present? ? "failed" : row[:status].to_s),
          summary: action_log&.log_text.to_s.presence || failure&.error_message.to_s.presence || row[:error_message].to_s.presence || "No final output captured yet.",
          error_class: failure&.error_class.to_s.presence,
          error_message: action_log&.error_message.to_s.presence || failure&.error_message.to_s.presence || row[:error_message].to_s.presence,
          metadata: compact_data(action_log&.metadata)
        }.compact
      end

      def build_technical_data(action_log:, llm_events:, ai_analyses:, story_rows:)
        rows = []
        rows << {
          source: "profile_action_log",
          payload: compact_data(action_log.metadata)
        } if action_log&.metadata.is_a?(Hash)

        llm_events.first(4).each do |event|
          rows << {
            source: "instagram_profile_event",
            payload: {
              event_id: event.id,
              event_kind: event.kind,
              llm_comment_status: event.llm_comment_status,
              llm_comment_model: event.llm_comment_model,
              llm_comment_provider: event.llm_comment_provider,
              generated_comment: event.llm_generated_comment.to_s.presence&.byteslice(0, 280),
              relevance_score: event.llm_comment_relevance_score,
              llm_comment_metadata: compact_data(event.llm_comment_metadata),
              metadata: compact_data(event.metadata)
            }.compact
          }
        end

        ai_analyses.first(4).each do |analysis|
          rows << {
            source: "ai_analysis",
            payload: {
              analysis_id: analysis.id,
              purpose: analysis.purpose,
              provider: analysis.provider,
              model: analysis.model,
              status: analysis.status,
              started_at: analysis.started_at&.iso8601,
              finished_at: analysis.finished_at&.iso8601,
              response_excerpt: analysis.response_text.to_s.presence&.byteslice(0, 320),
              analysis: compact_data(analysis.analysis),
              metadata: compact_data(analysis.metadata)
            }.compact
          }
        end

        story_rows.first(4).each do |story|
          metadata = story.metadata.is_a?(Hash) ? story.metadata : {}
          rows << {
            source: "instagram_story",
            payload: {
              story_id: story.story_id,
              media_type: story.media_type,
              processing_status: story.processing_status,
              processed: story.processed,
              processed_at: story.processed_at&.iso8601,
              metadata: compact_data(
                metadata.slice(
                  "processing_metadata",
                  "generated_response_suggestions",
                  "content_understanding",
                  "face_count",
                  "content_signals",
                  "ocr_text",
                  "transcript",
                  "object_detections",
                  "scenes"
                )
              )
            }.compact
          }
        end

        rows.first(12)
      end

      def serialize_api_call(call)
        metadata = call.metadata.is_a?(Hash) ? call.metadata : {}
        {
          occurred_at: call.occurred_at&.iso8601,
          provider: call.provider,
          operation: call.operation,
          category: call.category,
          status: call.status,
          http_status: call.http_status,
          latency_ms: call.latency_ms,
          input_tokens: call.input_tokens,
          output_tokens: call.output_tokens,
          total_tokens: call.total_tokens,
          error_message: call.error_message.to_s.presence,
          metadata: compact_data(metadata)
        }.compact
      end

      def serialize_ingestion(row)
        {
          created_at: row.created_at&.iso8601,
          attachment_name: row.attachment_name,
          record_type: row.record_type,
          record_id: row.record_id,
          blob_filename: row.blob_filename,
          blob_content_type: row.blob_content_type,
          blob_byte_size: row.blob_byte_size,
          metadata: compact_data(row.metadata)
        }.compact
      end

      def compact_data(value, depth: 0, max_depth: 3)
        return nil if value.nil?
        return "[depth_limit]" if depth >= max_depth

        case value
        when Hash
          compacted = {}
          value.to_h.each do |key, item|
            normalized = compact_data(item, depth: depth + 1, max_depth: max_depth)
            next if normalized.blank? && normalized != false && normalized != 0

            compacted[key.to_s] = normalized
            break if compacted.length >= 20
          end
          compacted
        when Array
          value.first(10).map { |item| compact_data(item, depth: depth + 1, max_depth: max_depth) }.compact
        when String
          text = value.to_s.strip
          return nil if text.blank?

          text.byteslice(0, 320)
        when Time, Date, DateTime
          value.iso8601
        else
          value
        end
      rescue StandardError
        value.to_s.byteslice(0, 320)
      end
    end
  end
end
