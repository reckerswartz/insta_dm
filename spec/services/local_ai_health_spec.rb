require "rails_helper"

RSpec.describe Ops::LocalAiHealth do
  before do
    Rails.cache.delete(Ops::LocalAiHealth::CACHE_KEY)
  end

  after do
    Rails.cache.delete(Ops::LocalAiHealth::CACHE_KEY)
  end

  it "returns cached health status without forcing external checks" do
    cached = {
      ok: true,
      checked_at: 10.minutes.ago.iso8601(3),
      details: {
        microservice: { ok: true, services: { "vision" => true } },
        ollama: { ok: true, models: [ "mistral:7b" ] }
      }
    }
    allow(Rails.cache).to receive(:read).with(Ops::LocalAiHealth::CACHE_KEY).and_return(cached)

    allow(Ai::LocalMicroserviceClient).to receive(:new).and_raise("should not call live health")
    allow(Ai::OllamaClient).to receive(:new).and_raise("should not call live health")

    status = Ops::LocalAiHealth.check(force: false, refresh_if_stale: false)

    assert_equal true, status[:ok]
    assert_equal "cache", status[:source]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(status[:stale])
  end

  it "performs a live check when forced" do
    allow(Rails.cache).to receive(:read).with(Ops::LocalAiHealth::CACHE_KEY).and_return(nil)
    allow(Rails.cache).to receive(:write)

    allow(Ai::LocalMicroserviceClient).to receive(:new).and_return(
      instance_double(Ai::LocalMicroserviceClient, test_connection!: { ok: true, services: { "vision" => true } })
    )
    allow(Ai::OllamaClient).to receive(:new).and_return(
      instance_double(Ai::OllamaClient, test_connection!: { ok: true, models: [ "mistral:7b" ] })
    )

    status = Ops::LocalAiHealth.check(force: true)

    assert_equal true, status[:ok]
    assert_equal "live", status[:source]
    assert_equal false, ActiveModel::Type::Boolean.new.cast(status[:stale])
  end
end
