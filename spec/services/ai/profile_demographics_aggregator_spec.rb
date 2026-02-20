require "rails_helper"
require "securerandom"

RSpec.describe Ai::ProfileDemographicsAggregator do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }

  it "normalizes JSON output from local aggregation LLM" do
    service = described_class.new(account: account, model: "mistral:test")
    client = instance_double(Ai::LocalMicroserviceClient)
    allow(service).to receive(:local_client).and_return(client)
    allow(client).to receive(:generate_text_json!).and_return(
      json: {
        "profile_inference" => {
          "age" => "29",
          "age_range" => "25-30",
          "age_confidence" => "1.7",
          "gender" => "female",
          "gender_indicators" => [ "she/her", "", nil ],
          "gender_confidence" => "0.88",
          "location" => "Berlin",
          "location_signals" => [ "germany", "europe" ],
          "location_confidence" => "0.62",
          "evidence" => "Profile bio mentions Berlin.",
          "why" => "Repeated location cues."
        },
        "post_inferences" => [
          {
            "shortcode" => "abc123",
            "source_type" => "post",
            "source_ref" => "12",
            "age" => "30",
            "gender" => "female",
            "location" => "Berlin",
            "confidence" => "1.2",
            "evidence" => "Caption context",
            "relevant" => "1"
          },
          {
            "shortcode" => "",
            "source_type" => "post"
          }
        ]
      }
    )

    result = service.aggregate!(dataset: { analysis_pool: {} })

    expect(client).to have_received(:generate_text_json!).with(
      hash_including(
        model: "mistral:test",
        temperature: 0.1,
        max_output_tokens: 1600,
        usage_category: "report_generation"
      )
    )

    expect(result[:ok]).to eq(true)
    expect(result[:source]).to eq("json_aggregator_llm")
    expect(result.dig(:profile_inference, :age)).to eq(29)
    expect(result.dig(:profile_inference, :age_confidence)).to eq(1.0)
    expect(result.dig(:profile_inference, :gender_indicators)).to eq([ "she/her" ])
    expect(result.dig(:profile_inference, :location_signals)).to eq([ "germany", "europe" ])

    expect(result[:post_inferences].length).to eq(1)
    expect(result[:post_inferences].first).to include(
      shortcode: "abc123",
      confidence: 1.0,
      relevant: true
    )
  end

  it "falls back to heuristic aggregation when LLM response is blank" do
    service = described_class.new(account: account)
    client = instance_double(Ai::LocalMicroserviceClient)
    allow(service).to receive(:local_client).and_return(client)
    allow(client).to receive(:generate_text_json!).and_return(json: nil)

    dataset = {
      analysis_pool: {
        profile_demographics: [
          { "age" => 20, "gender" => "female", "location" => "NYC" },
          { "age" => 22, "gender" => "female", "location" => "NYC" }
        ],
        post_demographics: [
          { age: 24, gender: "female", location: "Boston" }
        ]
      }
    }

    result = service.aggregate!(dataset: dataset)

    expect(result[:ok]).to eq(true)
    expect(result[:source]).to eq("heuristic_fallback")
    expect(result[:error]).to eq("aggregator_response_blank")
    expect(result.dig(:profile_inference, :age)).to eq(22)
    expect(result.dig(:profile_inference, :age_range)).to eq("20-24")
    expect(result.dig(:profile_inference, :gender)).to eq("female")
    expect(result.dig(:profile_inference, :location)).to eq("NYC")
    expect(result.dig(:profile_inference, :location_signals)).to eq([ "NYC", "Boston" ])
    expect(result[:post_inferences]).to eq([])
  end

  it "falls back to heuristic mode when local client raises an error" do
    service = described_class.new(account: account)
    client = instance_double(Ai::LocalMicroserviceClient)
    allow(service).to receive(:local_client).and_return(client)
    allow(client).to receive(:generate_text_json!).and_raise(StandardError, "timeout")

    result = service.aggregate!(dataset: { analysis_pool: { profile_demographics: [], post_demographics: [] } })

    expect(result[:ok]).to eq(true)
    expect(result[:source]).to eq("heuristic_fallback")
    expect(result[:error]).to eq("timeout")
    expect(result.dig(:profile_inference, :age)).to be_nil
    expect(result.dig(:profile_inference, :gender)).to be_nil
    expect(result.dig(:profile_inference, :location)).to be_nil
  end
end
