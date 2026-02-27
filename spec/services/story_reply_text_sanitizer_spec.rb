require "rails_helper"

RSpec.describe StoryReplyTextSanitizer do
  it "removes wrapping quotes and trailing commas" do
    expect(described_class.call("\"Nice frame\",")).to eq("Nice frame")
  end

  it "keeps natural sentence punctuation" do
    expect(described_class.call("\"Great shot!\",")).to eq("Great shot!")
  end

  it "returns blank for empty input" do
    expect(described_class.call("   ")).to eq("")
  end
end
