module Ai
  module Providers
    class LocalProvider < BaseProvider
      def initialize(setting: nil, video_frame_change_detector_service: VideoFrameChangeDetectorService.new)
        super(setting: setting)
        @video_frame_change_detector_service = video_frame_change_detector_service
      end

      def key
        "local"
      end

      def supports_profile?
        true
      end

      def supports_post_image?
        true
      end

      def supports_post_video?
        true
      end

      def requires_api_key?
        false
      end

      def test_key!
        # Test both microservice and Ollama
        microservice_result = client.test_connection!
        ollama_result = ollama_client.test_connection!
        
        if microservice_result[:ok] && ollama_result[:ok]
          { 
            ok: true, 
            message: "Local AI services are healthy",
            microservice: microservice_result[:services],
            ollama: ollama_result[:models]
          }
        else
          errors = []
          errors << "Microservice: #{microservice_result[:message]}" unless microservice_result[:ok]
          errors << "Ollama: #{ollama_result[:message]}" unless ollama_result[:ok]
          
          { ok: false, message: errors.join(" | ") }
        end
      rescue StandardError => e
        { ok: false, message: e.message.to_s }
      end

      def analyze_profile!(profile_payload:, media: nil)
        image_labels = []

        Array(media).each do |item|
          next unless item.is_a?(Hash)

          if item[:url].to_s.start_with?("http://", "https://")
            vision = client.analyze_image_uri!(item[:url], features: image_features)
            image_labels.concat(extract_image_labels(vision))
          elsif item[:bytes].present?
            vision = client.analyze_image_bytes!(item[:bytes], features: image_features)
            image_labels.concat(extract_image_labels(vision))
          end
        rescue StandardError => e
          image_labels << "image_analysis_error:#{e.class.name}"
        end

        bio = profile_payload[:bio].to_s
        recent_messages = Array(profile_payload[:recent_outgoing_messages]).map { |m| m[:body].to_s }.join(" ")
        combined = [ bio, recent_messages ].join(" ").downcase
        demo = infer_demographic_estimates(text: combined, bio: bio, labels: image_labels)

        languages = []
        languages << { language: "english", confidence: 0.7, evidence: "ASCII text in bio/messages" } if combined.match?(/[a-z]{3,}/)

        analysis = {
          "summary" => "Rule-based local AI analysis from profile text and vision labels.",
          "languages" => languages,
          "likes" => image_labels.first(10),
          "dislikes" => [],
          "intent_labels" => [ "unknown" ],
          "conversation_hooks" => image_labels.first(3).map { |label| { "hook" => "Ask about #{label}", "evidence" => "vision_label:#{label}" } },
          "personalization_tokens" => image_labels.first(5),
          "no_go_zones" => [],
          "writing_style" => {
            "tone" => infer_tone(combined),
            "formality" => infer_formality(combined),
            "emoji_usage" => combined.match?(/[^\x00-\x7F]/) ? "present" : "low",
            "slang_level" => infer_slang(combined),
            "evidence" => "Derived from bio + latest outgoing messages."
          },
          "response_style_prediction" => "unknown",
          "engagement_probability" => image_labels.any? ? 0.55 : 0.35,
          "recommended_next_action" => image_labels.any? ? "comment" : "review",
          "demographic_estimates" => {
            "age" => demo[:age],
            "age_confidence" => demo[:age_confidence],
            "gender" => demo[:gender],
            "gender_confidence" => demo[:gender_confidence],
            "location" => demo[:location],
            "location_confidence" => demo[:location_confidence],
            "evidence" => demo[:evidence]
          },
          "self_declared" => {
            "age" => extract_age(bio),
            "gender" => nil,
            "location" => nil,
            "pronouns" => extract_pronouns(bio),
            "other" => nil
          },
          "suggested_dm_openers" => [
            "Your recent posts are a vibe, what are you into most these days? ✨",
            "Okay your content style is low-key fire, what inspired it? 🔥",
            "Your feed feels super intentional, got any creator recs?",
            "Not gonna lie, your profile energy is elite. What do you like posting most?",
            "Your page is giving main-character energy, what are you building next? 👀"
          ],
          "suggested_comment_templates" => [
            "This is such a vibe 🔥",
            "Okay this ate, love this one 👏",
            "Clean shot, super satisfying fr",
            "This goes hard, great share ✨",
            "Big fan of this style, keep it coming 🙌"
          ],
          "confidence_notes" => "Built with local AI models to minimize cost; output is conservative and evidence-driven.",
          "why_not_confident" => "Limited structured text/bio and limited image context."
        }

        {
          model: "local-ai-vision+rules",
          prompt: {
            provider: key,
            image_count: Array(media).length,
            rule_based: true
          },
          response_text: "local_ai_rule_based_analysis",
          response_raw: { image_labels: image_labels },
          analysis: analysis
        }
      end

      def analyze_post!(post_payload:, media: nil)
        media_hash = media.is_a?(Hash) ? media : {}
        labels = []
        raw = {}
        image_description = nil

        case media_hash[:type].to_s
        when "image"
          vision, vision_warning = safe_media_analysis(stage: "image_analysis", media_type: "image") do
            analyze_image_media(media_hash)
          end
          raw[:vision] = vision
          labels = extract_image_labels(vision)
          if vision_warning
            labels << warning_label_for_error(vision_warning[:error_class], prefix: "image_analysis_error")
            raw[:vision_warning] = vision_warning
          end
          labels = labels.uniq
          image_description =
            if labels.any?
              build_image_description_from_vision(vision, labels: labels)
            else
              "Image analysis unavailable."
            end
        when "video"
          mode = classify_video_processing(media_hash)
          raw[:video_processing] = (mode[:metadata].is_a?(Hash) ? mode[:metadata] : {}).merge(
            processing_mode: mode[:processing_mode].to_s,
            static: ActiveModel::Type::Boolean.new.cast(mode[:static]),
            duration_seconds: mode[:duration_seconds]
          ).compact
          if mode[:processing_mode].to_s == "static_image" && mode[:frame_bytes].present?
            static_media = {
              type: "image",
              content_type: mode[:frame_content_type].to_s.presence || "image/jpeg",
              bytes: mode[:frame_bytes]
            }
            vision, vision_warning = safe_media_analysis(stage: "image_analysis", media_type: "image") do
              analyze_image_media(static_media)
            end
            raw[:vision] = vision
            labels = extract_image_labels(vision)
            if vision_warning
              labels << warning_label_for_error(vision_warning[:error_class], prefix: "image_analysis_error")
              raw[:vision_warning] = vision_warning
            end
            labels = labels.uniq
            image_description =
              if labels.any?
                "Static video detected; analyzed representative frame. #{build_image_description_from_vision(vision, labels: labels)}".strip
              else
                "Static video detected, but frame analysis was unavailable."
              end
          else
            video, video_warning = safe_media_analysis(stage: "video_analysis", media_type: "video") do
              analyze_video_media(media_hash)
            end
            raw[:video] = video
            labels = extract_video_labels(video)
            if video_warning
              labels << warning_label_for_error(video_warning[:error_class], prefix: "video_analysis_error")
              raw[:video_warning] = video_warning
            end
            labels = labels.uniq
            image_description =
              if labels.any?
                build_image_description_from_video(video, labels: labels)
              else
                "Video analysis unavailable."
              end
          end
        else
          labels = []
          image_description = "No image or video content available for visual description."
        end

        visual_labels = meaningful_visual_labels(labels)
        detected_face_count = extract_face_count_from_raw(raw)
        if detected_face_count.positive? && !visual_labels.include?("person")
          visual_labels << "person"
        end
        visual_labels = visual_labels.uniq
        image_description = unavailable_visual_description(raw: raw, media_type: media_hash[:type]) if visual_labels.empty?

        author_tags = Array(post_payload.dig(:author_profile, :tags)).map(&:to_s)
        ignore_tags = Array(post_payload.dig(:rules, :ignore_if_tagged)).map(&:to_s)
        prefer_tags = Array(post_payload.dig(:rules, :prefer_interact_if_tagged)).map(&:to_s)

        author_type = infer_author_type(author_tags)
        ignored = !(author_tags & ignore_tags).empty?
        preferred = !(author_tags & prefer_tags).empty?

        relevant = if ignored
          false
        elsif preferred
          true
        else
          visual_labels.any?
        end

        actions = if ignored
          [ "ignore" ]
        elsif preferred
          [ "review", "like_suggestion", "comment_suggestion" ]
        else
          [ "review" ]
        end

        comment_generation =
          if visual_labels.any?
            generate_engagement_comments_with_fallback(
              post_payload: post_payload,
              image_description: image_description,
              labels: visual_labels,
              author_type: author_type
            )
          else
            skipped_comment_generation_for_missing_visuals(raw: raw, media_type: media_hash[:type])
          end

        {
          model: [ "local-ai-vision-video+rules", comment_generation[:model] ].compact.join("+"),
          prompt: {
            provider: key,
            media_type: media_hash[:type].to_s,
            rule_based: true
          },
          response_text: "local_ai_rule_based_post_analysis",
          response_raw: raw.merge(
            comment_generation: {
              status: comment_generation[:status],
              source: comment_generation[:source],
              fallback_used: comment_generation[:fallback_used],
              model: comment_generation[:model],
              error_message: comment_generation[:error_message],
              raw: comment_generation[:raw]
            }
          ),
          analysis: {
            "image_description" => image_description,
            "relevant" => relevant,
            "author_type" => author_type,
            "topics" => visual_labels.first(12),
            "detected_face_count" => detected_face_count,
            "visual_signal_count" => visual_labels.length,
            "sentiment" => "unknown",
            "suggested_actions" => actions,
            "recommended_next_action" => actions.first || "review",
            "engagement_score" => visual_labels.any? ? 0.6 : 0.2,
            "comment_suggestions" => comment_generation[:comment_suggestions] || 
              (JSON.parse(comment_generation[:raw][:response])&.dig("comment_suggestions") rescue []),
            "comment_generation_status" => comment_generation[:status],
            "comment_generation_source" => comment_generation[:source],
            "comment_generation_fallback_used" => ActiveModel::Type::Boolean.new.cast(comment_generation[:fallback_used]),
            "comment_generation_error" => comment_generation[:error_message].to_s.presence,
            "personalization_tokens" => visual_labels.first(5),
            "video_processing_mode" => mode_for(media_hash: media_hash, raw: raw),
            "video_static_detected" => static_video_detected?(media_hash: media_hash, raw: raw),
            "confidence" => visual_labels.any? ? 0.65 : 0.2,
            "evidence" => visual_labels.any? ? "Local AI visual signals: #{visual_labels.first(6).join(', ')}" : "No verified visual signals detected; comment generation skipped"
          }
        }
      end

      private

      def client
        @client ||= Ai::LocalMicroserviceClient.new
      end

      def ollama_client
        @ollama_client ||= Ai::OllamaClient.new
      end

      def image_features
        [
          { type: "LABEL_DETECTION", maxResults: 15 },
          { type: "TEXT_DETECTION", maxResults: 10 },
          { type: "FACE_DETECTION", maxResults: 8 }
        ]
      end

      def classify_video_processing(media)
        bytes = media[:bytes]
        return {
          processing_mode: "dynamic_video",
          frame_bytes: nil,
          frame_content_type: nil,
          metadata: { reason: "video_bytes_missing" }
        } if bytes.blank?

        result = @video_frame_change_detector_service.classify(
          video_bytes: bytes,
          reference_id: media[:reference_id].to_s.presence || "post_media",
          content_type: media[:content_type]
        )
        result.is_a?(Hash) ? result : { processing_mode: "dynamic_video", metadata: { reason: "frame_change_detector_invalid_result" } }
      rescue StandardError => e
        {
          processing_mode: "dynamic_video",
          frame_bytes: nil,
          frame_content_type: nil,
          metadata: {
            reason: "frame_change_detection_failed",
            error_class: e.class.name,
            error_message: normalize_error_message(e.message)
          }
        }
      end

      def mode_for(media_hash:, raw:)
        return nil unless media_hash[:type].to_s == "video"

        raw.dig(:video_processing, :processing_mode).to_s.presence || "dynamic_video"
      end

      def static_video_detected?(media_hash:, raw:)
        return false unless media_hash[:type].to_s == "video"

        raw.dig(:video_processing, :processing_mode).to_s == "static_image"
      end

      def analyze_image_media(media)
        if media[:bytes].present?
          # Ensure bytes are properly encoded for binary data
          bytes_data = media[:bytes].is_a?(String) ? media[:bytes].force_encoding("BINARY") : media[:bytes]
          client.analyze_image_bytes!(bytes_data, features: image_features)
        elsif media[:url].to_s.start_with?("http://", "https://")
          client.analyze_image_uri!(media[:url], features: image_features)
        else
          {}
        end
      end

      def analyze_video_media(media)
        bytes = media[:bytes]
        raise "Video blob unavailable" if bytes.blank?

        client.analyze_video_bytes!(bytes, features: [ "LABEL_DETECTION", "SHOT_CHANGE_DETECTION" ])
      end

      def extract_image_labels(vision_response)
        labels = Array(vision_response["labelAnnotations"]).map { |v| v["description"].to_s.downcase.strip }.reject(&:blank?)
        texts = Array(vision_response["textAnnotations"]).map { |v| v["description"].to_s.downcase.strip }.reject(&:blank?)
        faces = Array(vision_response["faceAnnotations"]).length
        labels << "person" if faces.positive?
        (labels + texts.first(2)).uniq
      end

      def extract_video_labels(video_response)
        ann = video_response.dig("response", "annotationResults", 0)
        arr = Array(ann&.dig("segmentLabelAnnotations")) + Array(ann&.dig("shotLabelAnnotations"))
        arr.map { |item| item.dig("entity", "description").to_s.downcase.strip }.reject(&:blank?).uniq
      end

      def infer_author_type(tags)
        return "relative" if tags.include?("relative")
        return "friend" if tags.include?("friend") || tags.include?("female_friend") || tags.include?("male_friend")
        return "page" if tags.include?("page")
        return "personal_user" if tags.include?("personal_user")

        "unknown"
      end

      def build_comment_suggestions(labels:, description:)
        desc = description.to_s.strip
        topic = labels.first.to_s.strip
        anchor = topic.presence

        if desc.blank? && anchor.blank?
          return []
        end

        [
          "Okay this #{anchor} is elite 🔥",
          "This whole vibe is so clean, love it ✨",
          "Not gonna lie this one ate 👏",
          "The energy here is immaculate fr 😮‍💨",
          "This is super engaging, big fan 🙌"
        ]
      end

      def generate_engagement_comments(post_payload:, image_description:, labels:, author_type:)
        generator = Ai::LocalEngagementCommentGenerator.new(
          ollama_client: ollama_client,
          model: ollama_model
        )
        
        out = generator.generate!(
          post_payload: post_payload,
          image_description: image_description.to_s,
          topics: labels.first(12),
          author_type: author_type,
          historical_comments: extract_historical_comments(post_payload),
          historical_context: extract_historical_context(post_payload)
        )
        
        return out unless out[:error_message].present?

        {
          model: ollama_model,
          raw: {},
          source: "fallback",
          status: "error_fallback",
          fallback_used: true,
          error_message: out[:error_message],
          comment_suggestions: build_comment_suggestions(labels: labels, description: image_description)
        }
      end

      def generate_engagement_comments_with_fallback(post_payload:, image_description:, labels:, author_type:)
        generate_engagement_comments(
          post_payload: post_payload,
          image_description: image_description,
          labels: labels,
          author_type: author_type
        )
      rescue StandardError => e
        started_at = monotonic_started_at
        warning = {
          stage: "comment_generation",
          media_type: "post",
          error_class: e.class.name,
          error_message: normalize_error_message(e.message)
        }
        record_provider_warning!(
          warning: warning,
          started_at: started_at,
          category: "text_generation"
        )
        {
          model: ollama_model,
          raw: {},
          source: "fallback",
          status: "error_fallback",
          fallback_used: true,
          error_message: warning[:error_message],
          comment_suggestions: build_comment_suggestions(labels: labels, description: image_description)
        }
      end

      def meaningful_visual_labels(labels)
        Array(labels).map(&:to_s).map(&:downcase).map(&:strip).reject(&:blank?).reject do |label|
          label.start_with?("image_analysis_error:", "video_analysis_error:")
        end.uniq
      end

      def extract_face_count_from_raw(raw)
        vision_faces = Array(raw.dig(:vision, "faceAnnotations")).length
        vision_faces.positive? ? vision_faces : Array(raw.dig(:vision, :faceAnnotations)).length
      rescue StandardError
        0
      end

      def unavailable_visual_description(raw:, media_type:)
        warning = raw[:vision_warning] || raw[:video_warning]
        if warning.is_a?(Hash)
          detail = warning[:error_message].to_s.presence || warning["error_message"].to_s.presence || "analysis_error"
          return "Visual analysis unavailable (#{detail.byteslice(0, 120)})."
        end

        case media_type.to_s
        when "image"
          "Image analysis unavailable or returned no verifiable visual signals."
        when "video"
          "Video analysis unavailable or returned no verifiable visual signals."
        else
          "No image or video content available for visual description."
        end
      end

      def skipped_comment_generation_for_missing_visuals(raw:, media_type:)
        {
          model: ollama_model,
          raw: {},
          source: "policy",
          status: "skipped_no_visual_signals",
          fallback_used: false,
          error_message: unavailable_visual_description(raw: raw, media_type: media_type),
          comment_suggestions: []
        }
      end

      def safe_media_analysis(stage:, media_type:)
        started_at = monotonic_started_at
        payload = yield
        [ payload, nil ]
      rescue StandardError => e
        warning = {
          stage: stage.to_s,
          media_type: media_type.to_s,
          error_class: e.class.name,
          error_message: normalize_error_message(e.message)
        }
        record_provider_warning!(
          warning: warning,
          started_at: started_at,
          category: stage.to_s == "video_analysis" ? "video_analysis" : "image_analysis"
        )
        [ {}, warning ]
      end

      def warning_label_for_error(error_class, prefix:)
        klass = error_class.to_s.presence || "UnknownError"
        "#{prefix}:#{klass}"
      end

      def record_provider_warning!(warning:, started_at:, category:)
        payload = warning.to_h.merge(provider: key)

        Ops::StructuredLogger.warn(
          event: "ai.local_provider.fallback",
          payload: payload
        )

        Ai::ApiUsageTracker.track_failure(
          provider: "local_ai_stack",
          operation: warning[:stage].to_s.presence || "unknown_stage",
          category: category,
          started_at: started_at,
          error: "#{warning[:error_class]}: #{warning[:error_message]}",
          metadata: payload
        )
      rescue StandardError
        nil
      end

      def monotonic_started_at
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.current.to_f
      end

      def normalize_error_message(message)
        text = message.to_s.strip
        text = "unknown error" if text.blank?
        text.byteslice(0, 280)
      end

      def ollama_model
        @ollama_model ||= setting&.config_value("ollama_model").to_s.presence || 
                          Rails.application.credentials.dig(:ollama, :model).to_s.presence || 
                          "mistral:7b"
      end

      def extract_historical_comments(post_payload)
        history = post_payload.dig(:rules, :engagement_history, :prior_story_items)
        Array(history).filter_map do |row|
          row = row.to_h if row.respond_to?(:to_h)
          row.is_a?(Hash) ? row[:sent_comment].to_s.presence || row["sent_comment"].to_s.presence : nil
        end
      rescue StandardError
        []
      end

      def extract_historical_context(post_payload)
        post_payload.dig(:rules, :historical_narrative_text).to_s
      rescue StandardError
        ""
      end

      def build_image_description_from_vision(vision, labels:)
        top_labels = labels.first(5)
        text = Array(vision["textAnnotations"]).first&.dig("description").to_s.strip

        parts = []
        parts << "Likely shows: #{top_labels.join(', ')}." if top_labels.any?
        parts << "Visible text: #{text.tr("\n", " ").byteslice(0, 120)}." if text.present?

        out = parts.join(" ").strip
        out.presence || "Image content appears visually clear but limited contextual details were detected."
      end

      def build_image_description_from_video(video, labels:)
        top = labels.first(6)
        return "Video frames indicate: #{top.join(', ')}." if top.any?

        "Video content analyzed with local AI models."
      end

      def infer_tone(text)
        return "enthusiastic" if text.include?("!")
        return "casual" if text.match?(/\b(hey|yo|lol|omg)\b/)

        "neutral"
      end

      def infer_formality(text)
        text.match?(/\b(please|thanks|regards)\b/) ? "formal" : "casual"
      end

      def infer_slang(text)
        text.match?(/\b(lol|lmao|bro|fam|idk|tbh)\b/) ? "medium" : "low"
      end

      def extract_age(text)
        m = text.match(/\b(i am|i'm)\s+(\d{2})\b/i)
        return nil unless m

        m[2].to_i
      end

      def extract_pronouns(text)
        return "she/her" if text.match?(/\bshe\s*\/\s*her\b/i)
        return "he/him" if text.match?(/\bhe\s*\/\s*him\b/i)
        return "they/them" if text.match?(/\bthey\s*\/\s*them\b/i)

        nil
      end

      def infer_demographic_estimates(text:, bio:, labels:)
        age =
          extract_age(bio) ||
          if text.match?(/\b(high school|class of 20\d{2})\b/)
            17
          elsif text.match?(/\b(student|college|university|campus)\b/)
            21
          elsif text.match?(/\b(mom|dad|parent)\b/)
            34
          else
            26
          end

        gender =
          if text.match?(/\b(she\/her|she her|woman|girl|mrs|ms)\b/)
            "female"
          elsif text.match?(/\b(he\/him|he him|man|boy|mr)\b/)
            "male"
          elsif text.match?(/\b(they\/them|non[- ]?binary)\b/)
            "non-binary"
          else
            "unknown"
          end

        location =
          if (m = text.match(/(?:📍|based in|from)\s+([a-z][a-z\s,.-]{2,40})/))
            m[1].to_s.split(/[|•]/).first.to_s.strip.titleize
          elsif text.match?(/\b(usa|us|united states)\b/)
            "United States"
          elsif text.match?(/\b(india|indian|hindi)\b/)
            "India"
          else
            "unknown"
          end

        {
          age: age,
          age_confidence: extract_age(bio).present? ? 0.75 : 0.3,
          gender: gender,
          gender_confidence: gender == "unknown" ? 0.2 : 0.35,
          location: location,
          location_confidence: location == "unknown" ? 0.2 : 0.35,
          evidence: "Estimated from bio/text pronouns, language hints, and local AI vision labels: #{Array(labels).first(4).join(', ')}"
        }
      end
    end
  end
end
