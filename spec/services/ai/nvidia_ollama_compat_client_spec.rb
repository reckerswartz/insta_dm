require "rails_helper"

RSpec.describe Ai::NvidiaOllamaCompatClient do
  before do
    Ai::ProviderRegistry.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: true, api_key: "nvapi-test")
  end

  describe "#generate" do
    it "routes to NVIDIA and returns an Ollama-shaped { model, response, done } hash" do
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.1-8b-instruct"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            model: "meta/llama-3.1-8b-instruct",
            choices: [{ message: { role: "assistant", content: "hello world" } }],
            usage: { prompt_tokens: 10, completion_tokens: 3 }
          }.to_json
        )

      result = described_class.new.generate(model: "llama3.2:3b", prompt: "say hi")

      expect(result["response"]).to eq("hello world")
      expect(result["model"]).to eq("meta/llama-3.1-8b-instruct")
      expect(result["done"]).to be(true)
      expect(result["prompt_eval_count"]).to eq(10)
      expect(result["eval_count"]).to eq(3)
    end

    it "routes models containing 'quality' through text_quality" do
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.3-70b-instruct"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: "q" } }] }.to_json)

      described_class.new.generate(model: "llama3.2:3b-quality", prompt: "hi")
    end

    it "forces response_format: json_object when format: 'json' is requested" do
      captured_body = nil
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: "{}" } }] }.to_json)

      described_class.new.generate(model: "llama3.2:3b", prompt: "hi", format: "json")
      expect(captured_body["response_format"]).to eq({ "type" => "json_object" })
    end

    it "accepts 'role:text_fast' / 'role:vision_primary' overrides" do
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.2-90b-vision-instruct"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: "ok" } }] }.to_json)

      described_class.new.generate(model: "role:vision_primary", prompt: "describe me")
    end
  end

  describe "#chat" do
    it "returns an Ollama-shaped { message: { role, content } } hash" do
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { role: "assistant", content: "yo" } }] }.to_json)

      result = described_class.new.chat(
        model: "llama3.2:3b",
        messages: [{ role: "user", content: "hi" }]
      )

      expect(result["message"]["role"]).to eq("assistant")
      expect(result["message"]["content"]).to eq("yo")
      expect(result["done"]).to be(true)
    end
  end
end
