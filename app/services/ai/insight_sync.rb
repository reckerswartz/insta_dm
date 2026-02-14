module Ai
  class InsightSync
    class << self
      def sync_profile!(analysis_record:, payload:, analysis_hash:)
        profile = analysis_record.analyzable
        return unless profile.is_a?(InstagramProfile)

        languages = Array(analysis_hash["languages"]).filter_map do |l|
          next unless l.is_a?(Hash)
          l["language"].to_s.strip.presence
        end

        primary_language = languages.first
        secondary_languages = languages.drop(1)

        writing_style = analysis_hash["writing_style"].is_a?(Hash) ? analysis_hash["writing_style"] : {}
        likes = normalize_string_array(analysis_hash["likes"])
        dislikes = normalize_string_array(analysis_hash["dislikes"])

        insight = InstagramProfileInsight.create!(
          instagram_account: analysis_record.instagram_account,
          instagram_profile: profile,
          ai_analysis: analysis_record,
          summary: analysis_hash["summary"].to_s,
          primary_language: primary_language,
          secondary_languages: secondary_languages,
          tone: writing_style["tone"].to_s.presence,
          formality: writing_style["formality"].to_s.presence,
          emoji_usage: writing_style["emoji_usage"].to_s.presence,
          slang_level: writing_style["slang_level"].to_s.presence,
          engagement_style: infer_engagement_style(writing_style: writing_style),
          profile_type: infer_profile_type(profile: profile, payload: payload),
          messageability_score: infer_messageability_score(payload),
          last_refreshed_at: Time.current,
          raw_analysis: analysis_hash
        )

        InstagramProfileMessageStrategy.create!(
          instagram_account: analysis_record.instagram_account,
          instagram_profile: profile,
          ai_analysis: analysis_record,
          instagram_profile_insight: insight,
          opener_templates: normalize_string_array(analysis_hash["suggested_dm_openers"]),
          comment_templates: normalize_string_array(analysis_hash["suggested_comment_templates"]),
          dos: (likes + normalize_string_array(analysis_hash["personalization_tokens"])).uniq.first(10),
          donts: (dislikes + normalize_string_array(analysis_hash["no_go_zones"])).uniq.first(10),
          cta_style: infer_cta_style(analysis_hash),
          best_topics: likes.first(15),
          avoid_topics: dislikes.first(15)
        )

        create_profile_evidences!(
          insight: insight,
          analysis_record: analysis_record,
          analysis_hash: analysis_hash,
          likes: likes,
          dislikes: dislikes
        )
      end

      def sync_post!(analysis_record:, analysis_hash:)
        post = analysis_record.analyzable
        return unless post.is_a?(InstagramPost)

        topics = normalize_string_array(analysis_hash["topics"])
        actions = normalize_string_array(analysis_hash["suggested_actions"])
        comments = normalize_string_array(analysis_hash["comment_suggestions"])

        post_insight = InstagramPostInsight.create!(
          instagram_account: analysis_record.instagram_account,
          instagram_post: post,
          ai_analysis: analysis_record,
          image_description: analysis_hash["image_description"].to_s.presence,
          relevant: to_bool(analysis_hash["relevant"]),
          author_type: analysis_hash["author_type"].to_s.presence,
          sentiment: analysis_hash["sentiment"].to_s.presence,
          topics: topics,
          suggested_actions: actions,
          comment_suggestions: comments,
          confidence: to_float(analysis_hash["confidence"]),
          evidence: analysis_hash["evidence"].to_s,
          engagement_score: to_float(analysis_hash["engagement_score"]) || to_float(analysis_hash["confidence"]),
          recommended_next_action: analysis_hash["recommended_next_action"].to_s.presence || actions.first,
          raw_analysis: analysis_hash
        )

        (topics + normalize_string_array(analysis_hash["personalization_tokens"])).uniq.each do |topic|
          InstagramPostEntity.create!(
            instagram_account: analysis_record.instagram_account,
            instagram_post: post,
            instagram_post_insight: post_insight,
            entity_type: topics.include?(topic) ? "topic" : "personalization_token",
            value: topic,
            confidence: to_float(analysis_hash["confidence"]),
            evidence_text: analysis_hash["evidence"].to_s,
            source_type: "ai_analysis",
            source_ref: analysis_record.id.to_s
          )
        end
      end

      private

      def create_profile_evidences!(insight:, analysis_record:, analysis_hash:, likes:, dislikes:)
        Array(analysis_hash["languages"]).each do |lang|
          next unless lang.is_a?(Hash)

          value = lang["language"].to_s.strip
          next if value.blank?

          InstagramProfileSignalEvidence.create!(
            instagram_account: analysis_record.instagram_account,
            instagram_profile: insight.instagram_profile,
            ai_analysis: analysis_record,
            instagram_profile_insight: insight,
            signal_type: "language",
            value: value,
            confidence: to_float(lang["confidence"]),
            evidence_text: lang["evidence"].to_s,
            source_type: "ai_analysis",
            source_ref: analysis_record.id.to_s,
            occurred_at: Time.current
          )
        end

        likes.each do |topic|
          InstagramProfileSignalEvidence.create!(
            instagram_account: analysis_record.instagram_account,
            instagram_profile: insight.instagram_profile,
            ai_analysis: analysis_record,
            instagram_profile_insight: insight,
            signal_type: "interest",
            value: topic,
            confidence: nil,
            evidence_text: "likes",
            source_type: "ai_analysis",
            source_ref: analysis_record.id.to_s,
            occurred_at: Time.current
          )
        end

        dislikes.each do |topic|
          InstagramProfileSignalEvidence.create!(
            instagram_account: analysis_record.instagram_account,
            instagram_profile: insight.instagram_profile,
            ai_analysis: analysis_record,
            instagram_profile_insight: insight,
            signal_type: "avoidance",
            value: topic,
            confidence: nil,
            evidence_text: "dislikes",
            source_type: "ai_analysis",
            source_ref: analysis_record.id.to_s,
            occurred_at: Time.current
          )
        end

        notes = analysis_hash["confidence_notes"].to_s.strip
        if notes.present?
          InstagramProfileSignalEvidence.create!(
            instagram_account: analysis_record.instagram_account,
            instagram_profile: insight.instagram_profile,
            ai_analysis: analysis_record,
            instagram_profile_insight: insight,
            signal_type: "confidence_note",
            value: nil,
            confidence: nil,
            evidence_text: notes,
            source_type: "ai_analysis",
            source_ref: analysis_record.id.to_s,
            occurred_at: Time.current
          )
        end
      end

      def infer_profile_type(profile:, payload:)
        tags = profile.profile_tags.pluck(:name)
        return "page" if tags.include?("page")
        return "personal" if tags.include?("personal_user") || tags.include?("friend")

        bio = payload[:bio].to_s.downcase
        return "business" if bio.match?(/\b(bookings|business|official|shop|store)\b/)

        "unknown"
      end

      def infer_messageability_score(payload)
        can_message = payload[:can_message]
        return 0.8 if can_message == true
        return 0.2 if can_message == false

        0.5
      end

      def infer_engagement_style(writing_style:)
        tone = writing_style["tone"].to_s
        formality = writing_style["formality"].to_s
        emoji = writing_style["emoji_usage"].to_s
        [tone, formality, emoji].reject(&:blank?).join("/").presence || "unknown"
      end

      def infer_cta_style(analysis_hash)
        first = normalize_string_array(analysis_hash["suggested_dm_openers"]).first.to_s
        return "question_based" if first.include?("?")

        "soft"
      end

      def normalize_string_array(value)
        Array(value).filter_map { |v| v.to_s.strip.presence }
      end

      def to_float(value)
        Float(value)
      rescue StandardError
        nil
      end

      def to_bool(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end
