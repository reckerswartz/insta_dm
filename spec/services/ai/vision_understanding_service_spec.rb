require "rails_helper"

RSpec.describe Ai::VisionUnderstandingService do
  it "retries with a single image when the model rejects multi-image requests" do
    client_class = Class.new do
      attr_reader :image_counts

      def initialize
        @image_counts = []
      end

      def chat_with_images(model:, prompt:, image_bytes_list:, temperature:, max_tokens:)
        @image_counts << image_bytes_list.length

        if image_bytes_list.length > 1
          raise RuntimeError, "Ollama error: HTTP 500 Internal Server Error - this model only supports one image while more than one image requested"
        end

        {
          "model" => model,
          "message" => {
            "content" => {
              summary: "A person near a skateboard.",
              topics: [ "gym" ],
              objects: [ "skateboard" ]
            }.to_json
          },
          "prompt_eval_count" => 42,
          "eval_count" => 18,
          "total_duration" => 123,
          "load_duration" => 45
        }
      end
    end

    client = client_class.new
    service = described_class.new(
      ollama_client: client,
      model: "llama3.2-vision:11b",
      enabled: true
    )

    result = service.summarize(
      image_bytes_list: [ "one", "two", "three" ],
      transcript: nil,
      candidate_topics: [ "fitness" ],
      media_type: "video"
    )

    expect(client.image_counts).to eq([ 3, 1 ])
    expect(result[:ok]).to eq(true)
    expect(result[:summary]).to include("skateboard")
    expect(result[:topics]).to include("fitness")
    expect(result[:topics]).to include("gym")
    expect(result[:objects]).to include("skateboard")
    expect(result.dig(:metadata, :model)).to eq("llama3.2-vision:11b")
    expect(result.dig(:metadata, :images_used)).to eq(1)
    expect(result.dig(:metadata, :single_image_retry)).to eq(true)
    expect(result.dig(:metadata, :retry_reason)).to eq("model_single_image_limit")
  end
end
