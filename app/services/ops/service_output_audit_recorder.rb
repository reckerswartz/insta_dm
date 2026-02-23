module Ops
  class ServiceOutputAuditRecorder
    MAX_ARRAY_ITEMS = 120
    MAX_METADATA_BYTES = 48_000

    class << self
      def record!(
        service_name:,
        execution_source: nil,
        status: "completed",
        run_id: nil,
        active_job_id: nil,
        queue_name: nil,
        produced: nil,
        referenced: nil,
        persisted_before: nil,
        persisted_after: nil,
        persisted_paths: nil,
        context: {},
        metadata: {}
      )
        produced_paths = normalize_paths(flatten_paths(produced))
        produced_leaf_keys = normalize_leaf_keys(flatten_leaf_keys(produced))
        referenced_paths = normalize_paths(flatten_paths(referenced))
        referenced_leaf_keys = normalize_leaf_keys(flatten_leaf_keys(referenced))

        computed_persisted_paths =
          if persisted_paths.present?
            normalize_paths(Array(persisted_paths))
          else
            diff_paths(before_value: persisted_before, after_value: persisted_after)
          end
        persisted_leaf_keys = normalize_leaf_keys(computed_persisted_paths.map { |path| leaf_from_path(path) })

        used_leaf_keys = normalize_leaf_keys(
          referenced_leaf_keys +
          persisted_leaf_keys +
          infer_used_keys_from_paths(
            produced_leaf_keys: produced_leaf_keys,
            persisted_paths: computed_persisted_paths,
            referenced_paths: referenced_paths
          )
        )
        unused_leaf_keys = normalize_leaf_keys(produced_leaf_keys - used_leaf_keys)
        ids = normalized_context_ids(context)

        ServiceOutputAudit.create!(
          service_name: service_name.to_s,
          execution_source: execution_source.to_s.presence,
          status: normalize_status(status),
          run_id: run_id.to_s.presence,
          active_job_id: active_job_id.to_s.presence,
          queue_name: queue_name.to_s.presence,
          instagram_account_id: ids[:instagram_account_id],
          instagram_profile_id: ids[:instagram_profile_id],
          instagram_profile_post_id: ids[:instagram_profile_post_id],
          instagram_profile_event_id: ids[:instagram_profile_event_id],
          produced_count: produced_leaf_keys.length,
          referenced_count: referenced_leaf_keys.length,
          persisted_count: persisted_leaf_keys.length,
          unused_count: unused_leaf_keys.length,
          produced_paths: produced_paths,
          produced_leaf_keys: produced_leaf_keys,
          referenced_paths: referenced_paths,
          persisted_paths: computed_persisted_paths,
          unused_leaf_keys: unused_leaf_keys,
          metadata: normalized_metadata(metadata),
          recorded_at: Time.current
        )
      rescue StandardError => e
        Ops::StructuredLogger.warn(
          event: "ops.service_output_audit.record_failed",
          payload: {
            service_name: service_name.to_s,
            execution_source: execution_source.to_s,
            error_class: e.class.name,
            error_message: e.message.to_s.byteslice(0, 320)
          }
        )
        nil
      end

      def post_persistence_snapshot(post)
        {
          ai_status: post.ai_status.to_s,
          ai_provider: post.ai_provider.to_s.presence,
          ai_model: post.ai_model.to_s.presence,
          analysis: deep_stringify(post.analysis.is_a?(Hash) ? post.analysis : {}),
          metadata: deep_stringify(post.metadata.is_a?(Hash) ? post.metadata : {})
        }.compact
      rescue StandardError
        {}
      end

      def event_persistence_snapshot(event)
        {
          llm_comment_status: event.llm_comment_status.to_s,
          llm_generated_comment: event.llm_generated_comment.to_s.presence,
          llm_comment_provider: event.llm_comment_provider.to_s.presence,
          llm_comment_model: event.llm_comment_model.to_s.presence,
          llm_comment_relevance_score: event.llm_comment_relevance_score,
          llm_comment_metadata: deep_stringify(event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}),
          metadata: deep_stringify(event.metadata.is_a?(Hash) ? event.metadata : {})
        }.compact
      rescue StandardError
        {}
      end

      private

      def normalize_status(value)
        status = value.to_s.presence || "completed"
        return status if status.in?(%w[completed failed skipped unknown])

        "unknown"
      rescue StandardError
        "unknown"
      end

      def normalized_context_ids(context)
        row = context.is_a?(Hash) ? context : {}

        {
          instagram_account_id: id_from(row[:account] || row["account"] || row[:instagram_account] || row["instagram_account"]),
          instagram_profile_id: id_from(row[:profile] || row["profile"] || row[:instagram_profile] || row["instagram_profile"]),
          instagram_profile_post_id: id_from(row[:post] || row["post"] || row[:instagram_profile_post] || row["instagram_profile_post"]),
          instagram_profile_event_id: id_from(row[:event] || row["event"] || row[:instagram_profile_event] || row["instagram_profile_event"])
        }
      rescue StandardError
        {}
      end

      def id_from(value)
        return value.id if value.respond_to?(:id)

        parsed = value.to_i
        parsed.positive? ? parsed : nil
      rescue StandardError
        nil
      end

      def flatten_paths(value, prefix: nil, out: [])
        case value
        when Hash
          value.each do |key, child|
            path = prefix.present? ? "#{prefix}.#{key}" : key.to_s
            flatten_paths(child, prefix: path, out: out)
          end
        when Array
          out << prefix.to_s if prefix.present?
        else
          out << prefix.to_s if prefix.present?
        end
        out
      rescue StandardError
        out
      end

      def flatten_leaf_keys(value, out: [])
        case value
        when Hash
          value.each do |key, child|
            key_name = key.to_s
            out << key_name if key_name.present?
            flatten_leaf_keys(child, out: out)
          end
        when Array
          value.each { |child| flatten_leaf_keys(child, out: out) }
        end
        out
      rescue StandardError
        out
      end

      def diff_paths(before_value:, after_value:)
        before_map = flatten_leaf_value_map(before_value)
        after_map = flatten_leaf_value_map(after_value)
        (before_map.keys | after_map.keys).each_with_object([]) do |path, out|
          out << path if before_map[path] != after_map[path]
        end
      rescue StandardError
        []
      end

      def flatten_leaf_value_map(value, prefix: nil, out: {})
        case value
        when Hash
          value.each do |key, child|
            path = prefix.present? ? "#{prefix}.#{key}" : key.to_s
            flatten_leaf_value_map(child, prefix: path, out: out)
          end
        when Array
          out[prefix.to_s] = normalized_scalar(value) if prefix.present?
        else
          out[prefix.to_s] = normalized_scalar(value) if prefix.present?
        end
        out
      rescue StandardError
        out
      end

      def normalized_scalar(value)
        case value
        when NilClass, Numeric, TrueClass, FalseClass
          value
        when String
          value.bytesize > 4_000 ? value.byteslice(0, 4_000) : value
        else
          deep_stringify(value)
        end
      rescue StandardError
        value.to_s
      end

      def infer_used_keys_from_paths(produced_leaf_keys:, persisted_paths:, referenced_paths:)
        path_tokens = Array(persisted_paths).map { |path| tokenize_path(path) }.flatten +
          Array(referenced_paths).map { |path| tokenize_path(path) }.flatten

        produced_leaf_keys.select do |leaf|
          token = leaf.to_s.downcase.strip
          token.present? && path_tokens.any? { |value| value == token || value.include?(token) || token.include?(value) }
        end
      rescue StandardError
        []
      end

      def tokenize_path(path)
        path.to_s.downcase.split(".").map(&:strip).reject(&:blank?)
      rescue StandardError
        []
      end

      def leaf_from_path(path)
        path.to_s.split(".").last.to_s
      rescue StandardError
        ""
      end

      def normalize_paths(paths)
        Array(paths).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(MAX_ARRAY_ITEMS)
      rescue StandardError
        []
      end

      def normalize_leaf_keys(keys)
        Array(keys).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(MAX_ARRAY_ITEMS)
      rescue StandardError
        []
      end

      def normalized_metadata(value)
        row = value.is_a?(Hash) ? deep_stringify(value) : {}
        json = JSON.generate(row)
        return row if json.bytesize <= MAX_METADATA_BYTES

        {
          "truncated" => true,
          "original_bytes" => json.bytesize,
          "preview" => json.byteslice(0, MAX_METADATA_BYTES)
        }
      rescue StandardError
        {}
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), out|
            out[key.to_s] = deep_stringify(child)
          end
        when Array
          value.first(MAX_ARRAY_ITEMS).map { |child| deep_stringify(child) }
        else
          value
        end
      end
    end
  end
end
