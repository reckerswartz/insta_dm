require "digest"
require "uri"

module Ai
  class Runner
    def initialize(account:)
      @account = account
    end

    def analyze!(
      purpose:,
      analyzable:,
      payload:,
      media: nil,
      media_fingerprint: nil,
      allow_cached: true,
      provider_options: {}
    )
      fingerprint = if purpose == "post"
        media_fingerprint.to_s.presence || compute_media_fingerprint(media)
      end

      if allow_cached && purpose == "post"
        cached = reusable_analysis_for(purpose: purpose, media_fingerprint: fingerprint)
        return build_cached_run(cached: cached, analyzable: analyzable, purpose: purpose, payload: payload, media_fingerprint: fingerprint) if cached
      end

      candidates = candidate_providers(purpose: purpose, media: media)
      failures = []

      candidates.each do |provider|
        analysis = AiAnalysis.create!(
          instagram_account: @account,
          analyzable: analyzable,
          purpose: purpose,
          provider: provider.key,
          model: provider.preferred_model.presence,
          status: "running",
          started_at: Time.current,
          media_fingerprint: fingerprint,
          metadata: {
            provider_display_name: provider.display_name,
            provider_options: (provider_options.is_a?(Hash) ? provider_options : {})
          }
        )

        begin
          result = Ai::ApiUsageTracker.with_context(instagram_account_id: @account.id, workflow: "ai_runner", purpose: purpose) do
            case purpose
            when "profile"
              provider.analyze_profile!(profile_payload: payload, media: media)
            when "post"
              provider.analyze_post!(post_payload: payload, media: media, provider_options: provider_options)
            else
              raise "Unsupported AI purpose: #{purpose}"
            end
          end

          analysis.update!(
            model: result[:model].presence || analysis.model,
            status: "succeeded",
            finished_at: Time.current,
            prompt: JSON.generate(result[:prompt] || {}),
            response_text: result[:response_text].to_s,
            analysis: result[:analysis],
            input_completeness_score: input_completeness_score(payload),
            confidence_score: confidence_score(purpose: purpose, analysis: result[:analysis]),
            evidence_count: evidence_count(purpose: purpose, analysis: result[:analysis]),
            signals_detected_count: signals_detected_count(purpose: purpose, analysis: result[:analysis]),
            prompt_version: "v1",
            schema_version: schema_version_for(purpose: purpose),
            metadata: (analysis.metadata || {}).merge(
              cache_hit: false,
              raw: result[:response_raw]
            ),
            error_message: nil
          )

          sync_materialized_insights!(purpose: purpose, analysis_record: analysis, payload: payload, analysis_hash: result[:analysis])

          return { record: analysis, result: result, provider: provider }
        rescue StandardError => e
          analysis.update!(status: "failed", finished_at: Time.current, error_message: e.message.to_s)
          failures << "#{provider.display_name}: #{e.message}"
        end
      end

      raise "All enabled AI providers failed. #{failures.join(' | ')}"
    end

    private

    def candidate_providers(purpose:, media:)
      settings = Ai::ProviderRegistry.enabled_settings.to_a
      raise "No AI providers are enabled. Configure one in Admin > AI Providers." if settings.empty?

      settings = filter_settings_by_daily_limit(settings: settings, purpose: purpose)
      candidates = settings.filter_map do |setting|
        provider = Ai::ProviderRegistry.build_provider(setting.provider, setting: setting)
        next nil unless provider.available?
        next nil unless supports_purpose?(provider, purpose: purpose, media: media)

        provider
      end

      raise "No enabled AI provider supports this analysis type." if candidates.empty?
      candidates
    end

    def reusable_analysis_for(purpose:, media_fingerprint:)
      return nil if media_fingerprint.blank?

      candidate = AiAnalysis.reusable_for(purpose: purpose, media_fingerprint: media_fingerprint).first
      return nil unless candidate
      return nil if purpose == "post" && legacy_post_comment_generation_payload?(candidate.analysis)

      candidate
    end

    def legacy_post_comment_generation_payload?(analysis_hash)
      return false unless analysis_hash.is_a?(Hash)
      return false unless analysis_hash.key?("comment_suggestions")
      return true if analysis_hash["comment_generation_status"].to_s == "error_fallback"
      return true if analysis_hash["comment_generation_status"].to_s.blank?
      return true if analysis_hash["evidence"].to_s.include?("No labels detected; used tag rules only")
      return true unless analysis_hash.key?("visual_signal_count")

      false
    end

    def build_cached_run(cached:, analyzable:, purpose:, payload:, media_fingerprint:)
      provider = provider_for_key(cached.provider)
      now = Time.current

      record = AiAnalysis.create!(
        instagram_account: @account,
        analyzable: analyzable,
        purpose: purpose,
        provider: cached.provider,
        model: cached.model,
        status: "succeeded",
        started_at: now,
        finished_at: now,
        prompt: cached.prompt,
        response_text: cached.response_text,
        analysis: cached.analysis,
        input_completeness_score: input_completeness_score(payload),
        confidence_score: cached.confidence_score,
        evidence_count: cached.evidence_count,
        signals_detected_count: cached.signals_detected_count,
        prompt_version: cached.prompt_version,
        schema_version: cached.schema_version,
        media_fingerprint: media_fingerprint,
        cache_hit: true,
        cached_from_ai_analysis_id: cached.id,
        metadata: (cached.metadata || {}).merge(
          cache_hit: true,
          reused_from_ai_analysis_id: cached.id,
          reused_at: now.iso8601
        )
      )

      sync_materialized_insights!(purpose: purpose, analysis_record: record, payload: payload, analysis_hash: cached.analysis)

      {
        record: record,
        result: {
          model: cached.model,
          prompt: parsed_json_or_hash(cached.prompt),
          response_text: cached.response_text.to_s,
          response_raw: cached.metadata,
          analysis: cached.analysis
        },
        provider: provider,
        cached: true
      }
    end

    def parsed_json_or_hash(value)
      return value if value.is_a?(Hash)

      JSON.parse(value.to_s)
    rescue StandardError
      {}
    end

    def provider_for_key(provider_key)
      Ai::ProviderRegistry.build_provider(provider_key)
    rescue StandardError
      Struct.new(:key, :display_name).new(provider_key.to_s, provider_key.to_s.humanize)
    end

    def filter_settings_by_daily_limit(settings:, purpose:)
      todays_counts = AiAnalysis.where(purpose: purpose, status: "succeeded")
        .where(created_at: Time.current.all_day)
        .group(:provider)
        .count

      with_load = settings.map do |setting|
        limit = integer_or_nil(setting.config_value("daily_limit"))
        used = todays_counts[setting.provider].to_i
        utilization = limit.to_i.positive? ? (used.to_f / limit.to_f) : 0.0
        [ setting, limit, used, utilization ]
      end

      available = with_load.reject { |_setting, limit, used, _utilization| limit.to_i.positive? && used >= limit }
      sorted = available.sort_by { |setting, _limit, _used, utilization| [ setting.priority.to_i, utilization, setting.provider ] }
      sorted.map(&:first)
    end

    def integer_or_nil(value)
      return nil if value.blank?

      Integer(value)
    rescue StandardError
      nil
    end

    def compute_media_fingerprint(media)
      item = media.is_a?(Array) ? media.first : media
      return nil unless item.is_a?(Hash)

      bytes = item[:bytes] || item["bytes"]
      return Digest::SHA256.hexdigest(bytes) if bytes.present?

      data_url = item[:image_data_url] || item["image_data_url"]
      return Digest::SHA256.hexdigest(data_url.to_s) if data_url.present?

      url = item[:url] || item["url"]
      normalized = normalize_url(url)
      return Digest::SHA256.hexdigest(normalized) if normalized.present?

      nil
    end

    def normalize_url(raw)
      value = raw.to_s.strip
      return nil if value.blank?

      uri = URI.parse(value)
      return value unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      "#{uri.scheme}://#{uri.host}#{uri.path}"
    rescue StandardError
      value
    end

    def supports_purpose?(provider, purpose:, media:)
      return provider.supports_profile? if purpose == "profile"

      return false unless purpose == "post"

      type = media.is_a?(Hash) ? media[:type].to_s : ""
      return provider.supports_post_video? if type == "video"

      provider.supports_post_image?
    end

    def sync_materialized_insights!(purpose:, analysis_record:, payload:, analysis_hash:)
      return unless analysis_hash.is_a?(Hash)

      case purpose
      when "profile"
        Ai::InsightSync.sync_profile!(analysis_record: analysis_record, payload: payload, analysis_hash: analysis_hash)
      when "post"
        Ai::InsightSync.sync_post!(analysis_record: analysis_record, analysis_hash: analysis_hash)
      end
    end

    def schema_version_for(purpose:)
      case purpose
      when "profile" then "profile_insights_v2"
      when "post" then "post_insights_v2"
      else "unknown"
      end
    end

    def input_completeness_score(payload)
      total = 0
      present = 0
      walk_payload(payload) do |value|
        total += 1
        present += 1 if value.present?
      end
      return nil if total <= 0

      (present.to_f / total).round(4)
    end

    def walk_payload(value, &block)
      case value
      when Hash
        value.each_value { |v| walk_payload(v, &block) }
      when Array
        if value.empty?
          block.call(nil)
        else
          value.each { |v| walk_payload(v, &block) }
        end
      else
        block.call(value)
      end
    end

    def confidence_score(purpose:, analysis:)
      return nil unless analysis.is_a?(Hash)

      if purpose == "post"
        val = analysis["confidence"]
        return Float(val).clamp(0.0, 1.0) rescue nil
      end

      langs = Array(analysis["languages"]).size
      likes = Array(analysis["likes"]).size
      ([(langs * 0.1) + (likes * 0.05), 1.0].min).round(4)
    end

    def evidence_count(purpose:, analysis:)
      return 0 unless analysis.is_a?(Hash)

      if purpose == "post"
        count = 0
        count += 1 if analysis["evidence"].to_s.present?
        count += Array(analysis["topics"]).size
        return count
      end

      count = 0
      count += Array(analysis["languages"]).size
      count += Array(analysis["likes"]).size
      count += Array(analysis["dislikes"]).size
      count += 1 if analysis["confidence_notes"].to_s.present?
      count
    end

    def signals_detected_count(purpose:, analysis:)
      return 0 unless analysis.is_a?(Hash)

      if purpose == "post"
        return Array(analysis["topics"]).size + Array(analysis["suggested_actions"]).size
      end

      self_declared = analysis["self_declared"].is_a?(Hash) ? analysis["self_declared"] : {}
      declared_count = self_declared.values.count(&:present?)

      Array(analysis["languages"]).size + Array(analysis["likes"]).size + declared_count
    end
  end
end
