require "rails_helper"

RSpec.describe Ai::NvidiaClient do
  let(:base_url) { "https://integrate.api.nvidia.com/v1" }
  let(:api_key)  { "nvapi-TEST-KEY" }
  subject(:client) do
    described_class.new(api_key: api_key, base_url: base_url, max_retries: 0)
  end

  describe "#chat!" do
    it "posts OpenAI-compatible chat payload and returns parsed JSON" do
      stub = stub_request(:post, "#{base_url}/chat/completions")
               .with(
                 headers: { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
                 body: hash_including(model: "meta/llama-3.3-70b-instruct")
               )
               .to_return(
                 status: 200,
                 headers: { "Content-Type" => "application/json" },
                 body: { id: "cmpl-1", model: "meta/llama-3.3-70b-instruct",
                         choices: [{ message: { role: "assistant", content: "ok" } }] }.to_json
               )

      result = client.chat!(
        model: "meta/llama-3.3-70b-instruct",
        messages: [{ role: "user", content: "hi" }],
        max_tokens: 8
      )

      expect(stub).to have_been_requested
      expect(result.dig("choices", 0, "message", "content")).to eq("ok")
    end

    it "raises AuthError on 401" do
      stub_request(:post, "#{base_url}/chat/completions")
        .to_return(status: 401, body: '{"error":"bad key"}')

      expect {
        client.chat!(model: "m", messages: [{ role: "user", content: "x" }])
      }.to raise_error(Ai::NvidiaClient::AuthError)
    end

    it "raises RateLimitError on 429 when retries are exhausted" do
      stub_request(:post, "#{base_url}/chat/completions")
        .to_return(status: 429, body: '{"error":"slow down"}', headers: { "Retry-After" => "0.01" })

      expect {
        client.chat!(model: "m", messages: [{ role: "user", content: "x" }])
      }.to raise_error(Ai::NvidiaClient::RateLimitError)
    end
  end

  describe "#embed!" do
    it "posts embedding payload with input_type extras" do
      stub = stub_request(:post, "#{base_url}/embeddings")
               .with(body: hash_including(model: "nvidia/nv-embedqa-e5-v5", input: ["a", "b"], input_type: "passage"))
               .to_return(
                 status: 200,
                 headers: { "Content-Type" => "application/json" },
                 body: { data: [{ embedding: [0.1, 0.2] }, { embedding: [0.3, 0.4] }] }.to_json
               )

      result = client.embed!(model: "nvidia/nv-embedqa-e5-v5", input: ["a", "b"], extra: { input_type: "passage" })

      expect(stub).to have_been_requested
      expect(result["data"].length).to eq(2)
    end
  end

  describe "#list_models!" do
    it "GETs /v1/models" do
      stub = stub_request(:get, "#{base_url}/models")
               .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                          body: { data: [{ id: "meta/llama-3.3-70b-instruct" }] }.to_json)

      result = client.list_models!

      expect(stub).to have_been_requested
      expect(result["data"].first["id"]).to eq("meta/llama-3.3-70b-instruct")
    end
  end

  describe ".image_data_url" do
    it "encodes bytes as a data URL" do
      url = described_class.image_data_url(bytes: "\x89PNG", mime_type: "image/png")
      expect(url).to start_with("data:image/png;base64,")
    end
  end

  describe "configuration error cases" do
    it "raises AuthError when api_key is blank" do
      empty_client = described_class.new(api_key: "", base_url: base_url, max_retries: 0)
      expect {
        empty_client.chat!(model: "m", messages: [{ role: "user", content: "x" }])
      }.to raise_error(Ai::NvidiaClient::AuthError, /not configured/)
    end
  end
end
