require "json"

module Ai
  class PostAnalyzer
    DEFAULT_MODEL = "grok-4-1-fast-reasoning".freeze

    def initialize(client: nil, model: nil)
      @client = client || Ai::XaiClient.new
      @model = model.presence || Rails.application.credentials.dig(:xai, :model).presence || DEFAULT_MODEL
    end

    def analyze!(post_payload:, image_data_url: nil)
      system = <<~SYS.strip
        You analyze an Instagram feed post payload and optionally an image.

        Output MUST be strict JSON. No markdown.

        Constraints:
        - Do NOT guess sensitive demographics (age, gender, ethnicity, religion, nationality, native place).
        - If the payload contains explicit self-declared information, you may repeat it as evidence.
        - Decide whether we should store this post (relevant) or ignore it (irrelevant) based on tags/rules in the payload.
        - Provide only safe, non-deceptive interaction suggestions.
        - Style for generated comments: modern Gen Z voice, light slang, playful energy, and occasional emojis.
        - Keep it socially engaging and authentic without being offensive, sexual, manipulative, or overfamiliar.
        - First produce a concise, visual image_description; then base comment suggestions on that description.
      SYS

      user = <<~TXT
        INPUT_POST_JSON:
        #{JSON.pretty_generate(post_payload)}

        Produce JSON with keys:
        - image_description: 1-3 sentence visual description of what is happening in the image
        - relevant: boolean
        - author_type: one of ["personal_user","friend","relative","page","unknown"]
        - topics: array of strings
        - sentiment: one of ["positive","neutral","negative","mixed","unknown"]
        - suggested_actions: array of strings from ["ignore","review","like_suggestion","comment_suggestion"]
        - recommended_next_action: one of ["ignore","review","comment_suggestion","like_suggestion"]
        - engagement_score: number 0-1
        - comment_suggestions: array of 5 short comments (friendly/contextual, Gen Z-style voice, based on image_description, may include emojis)
        - personalization_tokens: array of short contextual tokens we can safely reference
        - confidence: number 0-1
        - evidence: short string
      TXT

      images = []
      images << image_data_url.to_s if image_data_url.to_s.start_with?("data:image/")

      messages = [
        { role: "system", content: [ { type: "text", text: system } ] },
        { role: "user", content: build_user_content(text: user, images: images) }
      ]

      resp = @client.chat_completions!(
        model: @model,
        messages: messages,
        temperature: 0.2,
        usage_category: "report_generation",
        usage_context: { workflow: "post_analyzer" }
      )
      parsed = safe_parse_json(resp[:content])

      {
        model: @model,
        prompt: { system: system, user: user, images_count: images.length },
        response_text: resp[:content],
        response_raw: resp[:raw],
        analysis: parsed
      }
    end

    private

    def build_user_content(text:, images:)
      out = [ { type: "text", text: text } ]
      Array(images).each do |url|
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
