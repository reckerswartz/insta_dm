require "json"

module Ai
  class ProfileAnalyzer
    DEFAULT_MODEL = "mistral:7b".freeze

    def initialize(client: nil, model: nil)
      @client = client || Ai::LocalMicroserviceClient.new
      @model = model.presence || DEFAULT_MODEL
    end

    def analyze!(profile_payload:, images: [])
      system = <<~SYS.strip
        You analyze Instagram profile data and produce a compact JSON report that can be used to draft friendly, respectful messages.

        Safety/constraints:
        - For demographics (age/gender/location), provide cautious estimates only when there is supporting evidence.
        - Use a modern, socially natural Gen Z-style voice for message/comment suggestions:
          light slang, playful phrasing, mild humor, and selective emojis.
        - Keep tone authentic and kind, sexual content, or manipulative language.
        - Output MUST be strict JSON (no markdown, no commentary).
      SYS

      user_text = <<~TXT
        INPUT_PAYLOAD_JSON:
        #{JSON.pretty_generate(profile_payload)}

        Produce JSON with keys:
        - summary: short 3-6 sentence summary of interests + tone + interaction style
        - languages: array of {language, confidence, evidence}
        - likes: array of strings (topics/content likely liked)
        - dislikes: array of strings (topics/content likely avoided)
        - intent_labels: array of strings from ["friendship","networking","business","flirting","unknown"]
        - conversation_hooks: array of {hook, evidence}
        - personalization_tokens: array of safe, non-sensitive details we can mention
        - no_go_zones: array of topics/styles to avoid
        - writing_style: {tone, formality, emoji_usage, slang_level, evidence}
        - response_style_prediction: one of ["short","medium","long","unknown"]
        - engagement_probability: number 0-1
        - recommended_next_action: one of ["dm","comment","wait","ignore","review"]
        - demographic_estimates: {age, age_confidence, gender, gender_confidence, location, location_confidence, evidence}
        - self_declared: {age, gender, location, pronouns, other}
        - suggested_dm_openers: 5 short openers in friendly Gen Z-style voice (light slang/humor/emojis when natural)
        - suggested_comment_templates: 5 short comment templates in the same voice
        - confidence_notes: short string describing what was/wasn't available
        - why_not_confident: short string listing missing signals that reduced confidence
      TXT

      messages = [
        { role: "system", content: [ { type: "text", text: system } ] },
        { role: "user", content: build_user_content(text: user_text, images: images) }
      ]

      resp = @client.chat_completions!(
        model: @model,
        messages: messages,
        temperature: 0.2,
        usage_category: "report_generation",
        usage_context: { workflow: "profile_analyzer" }
      )
      parsed = safe_parse_json(resp[:content])

      {
        model: @model,
        prompt: { system: system, user: user_text, images_count: images.length },
        response_text: resp[:content],
        response_raw: resp[:raw],
        analysis: parsed
      }
    end

    private

    def build_user_content(text:, images:)
      out = [ { type: "text", text: text } ]

      Array(images).each do |img|
        url = img.to_s.strip
        next if url.blank?
        out << { type: "image_url", image_url: { url: url } }
      end

      out
    end

    def safe_parse_json(text)
      JSON.parse(text.to_s)
    rescue StandardError
      { "parse_error" => true, "raw_text" => text.to_s }
    end
  end
end
