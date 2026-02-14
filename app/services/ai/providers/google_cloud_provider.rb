module Ai
  module Providers
    class GoogleCloudProvider < BaseProvider
      MAX_INLINE_VIDEO_BYTES = 10 * 1024 * 1024

      def key
        "google_cloud"
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

      def test_key!
        client.test_key!
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
          "summary" => "Rule-based Google Cloud analysis from profile text and vision labels.",
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
          "confidence_notes" => "Built without an LLM to minimize cost; output is conservative and evidence-driven.",
          "why_not_confident" => "Limited structured text/bio and limited image context."
        }

        {
          model: "google-cloud-vision+rules",
          prompt: {
            provider: key,
            image_count: Array(media).length,
            rule_based: true
          },
          response_text: "google_cloud_rule_based_analysis",
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
          vision = analyze_image_media(media_hash)
          raw[:vision] = vision
          labels = extract_image_labels(vision)
          image_description = build_image_description_from_vision(vision, labels: labels)
        when "video"
          video = analyze_video_media(media_hash)
          raw[:video] = video
          labels = extract_video_labels(video)
          image_description = build_image_description_from_video(video, labels: labels)
        else
          labels = []
          image_description = "No image or video content available for visual description."
        end

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
          labels.any?
        end

        actions = if ignored
          [ "ignore" ]
        elsif preferred
          [ "review", "like_suggestion", "comment_suggestion" ]
        else
          [ "review" ]
        end

        comment_generation = generate_engagement_comments(
          post_payload: post_payload,
          image_description: image_description,
          labels: labels,
          author_type: author_type
        )

        {
          model: [ "google-cloud-vision-videointelligence+rules", comment_generation[:model] ].compact.join("+"),
          prompt: {
            provider: key,
            media_type: media_hash[:type].to_s,
            rule_based: true
          },
          response_text: "google_cloud_rule_based_post_analysis",
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
            "topics" => labels.first(12),
            "sentiment" => "unknown",
            "suggested_actions" => actions,
            "recommended_next_action" => actions.first || "review",
            "engagement_score" => labels.any? ? 0.6 : 0.4,
            "comment_suggestions" => comment_generation[:comment_suggestions],
            "comment_generation_status" => comment_generation[:status],
            "comment_generation_source" => comment_generation[:source],
            "comment_generation_fallback_used" => ActiveModel::Type::Boolean.new.cast(comment_generation[:fallback_used]),
            "comment_generation_error" => comment_generation[:error_message].to_s.presence,
            "personalization_tokens" => labels.first(5),
            "confidence" => labels.any? ? 0.65 : 0.45,
            "evidence" => labels.any? ? "Vision/video labels: #{labels.first(5).join(', ')}" : "No labels detected; used tag rules only"
          }
        }
      end

      private

      def client
        @client ||= Ai::GoogleCloudClient.new(api_key: ensure_api_key!)
      end

      def image_features
        [
          { type: "LABEL_DETECTION", maxResults: 15 },
          { type: "TEXT_DETECTION", maxResults: 10 },
          { type: "SAFE_SEARCH_DETECTION" }
        ]
      end

      def analyze_image_media(media)
        if media[:bytes].present?
          client.analyze_image_bytes!(media[:bytes], features: image_features)
        elsif media[:url].to_s.start_with?("http://", "https://")
          client.analyze_image_uri!(media[:url], features: image_features)
        else
          {}
        end
      end

      def analyze_video_media(media)
        bytes = media[:bytes]
        raise "Video blob unavailable" if bytes.blank?
        raise "Video too large for inline Google Video Intelligence request" if bytes.bytesize > MAX_INLINE_VIDEO_BYTES

        op = client.analyze_video_bytes!(bytes, features: [ "LABEL_DETECTION", "SHOT_CHANGE_DETECTION", "EXPLICIT_CONTENT_DETECTION" ])
        name = op["name"].to_s
        return op if name.blank?

        3.times do
          sleep 2
          polled = client.fetch_video_operation!(name)
          return polled if polled["done"] == true
        end

        op
      end

      def extract_image_labels(vision_response)
        labels = Array(vision_response["labelAnnotations"]).map { |v| v["description"].to_s.downcase.strip }.reject(&:blank?)
        texts = Array(vision_response["textAnnotations"]).map { |v| v["description"].to_s.downcase.strip }.reject(&:blank?)
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
        anchor = topic.presence || "shot"

        if desc.blank? && anchor.blank?
          return [
            "This is such a vibe ✨",
            "Okay this ate fr 🔥",
            "Main feed energy right here 👏",
            "Low-key obsessed with this one 😮‍💨",
            "This goes hard, no notes 🙌"
          ]
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
        errors = []
        text_model_candidates.each do |model_name|
          generator = Ai::GoogleEngagementCommentGenerator.new(
            client: client,
            model: model_name
          )
          out = generator.generate!(
            post_payload: post_payload,
            image_description: image_description.to_s,
            topics: labels.first(12),
            author_type: author_type
          )
          return out unless model_unavailable_error?(out[:error_message])

          errors << "#{model_name}: #{out[:error_message]}"
        end

        {
          model: text_model_candidates.first.to_s,
          raw: {},
          source: "fallback",
          status: "error_fallback",
          fallback_used: true,
          error_message: errors.join(" | ").presence || "Comment generation unavailable",
          comment_suggestions: build_comment_suggestions(labels: labels, description: image_description)
        }
      end

      def text_model_candidates
        configured = [
          setting&.config_value("comment_model").to_s,
          setting&.config_value("model").to_s,
          Rails.application.credentials.dig(:google_cloud, :comment_model).to_s
        ].map(&:strip).reject(&:blank?)

        # Prefer stable models known to be broadly available in current v1beta responses.
        (configured + [
          "gemini-2.0-flash",
          "gemini-flash-latest",
          "gemini-2.5-flash"
        ]).uniq
      end

      def model_unavailable_error?(message)
        text = message.to_s.downcase
        text.include?("is not found") || text.include?("not supported for generatecontent")
      end

      def build_image_description_from_vision(vision, labels:)
        top_labels = labels.first(5)
        text = Array(vision["textAnnotations"]).first&.dig("description").to_s.strip
        safe = vision["safeSearchAnnotation"].is_a?(Hash) ? vision["safeSearchAnnotation"] : {}

        parts = []
        parts << "Likely shows: #{top_labels.join(', ')}." if top_labels.any?
        parts << "Visible text: #{text.tr("\n", " ").byteslice(0, 120)}." if text.present?
        if safe.any?
          flags = %w[adult violence racy].map { |k| "#{k}=#{safe[k.to_s]}" }.join(", ")
          parts << "Safety hints: #{flags}."
        end

        out = parts.join(" ").strip
        out.presence || "Image content appears visually clear but limited contextual details were detected."
      end

      def build_image_description_from_video(video, labels:)
        top = labels.first(6)
        return "Video frames indicate: #{top.join(', ')}." if top.any?

        op_name = video["name"].to_s
        if op_name.present?
          "Video analysis operation created (#{op_name}) with limited completed label details."
        else
          "Video content analyzed with limited semantic labels."
        end
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
          evidence: "Estimated from bio/text pronouns, language hints, and vision labels: #{Array(labels).first(4).join(', ')}"
        }
      end
    end
  end
end
