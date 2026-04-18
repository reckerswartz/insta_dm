require "rails_helper"

RSpec.describe Ai::NvidiaRateLimiter do
  let(:setting) do
    Ai::ProviderRegistry.ensure_settings!
    row = AiProviderSetting.for_provider("nvidia").for_role("text_fast").first!
    row.update!(enabled: true, api_key: "nvapi-test", rate_limit_rpm: rpm)
    row
  end

  describe "#throttle!" do
    context "when rate_limit_rpm is zero" do
      let(:rpm) { 0 }

      it "is a no-op (no Redis calls)" do
        redis = instance_double(Redis)
        limiter = described_class.new(redis: redis)
        expect(redis).not_to receive(:incr)
        limiter.throttle!(setting: setting)
      end
    end

    context "when rate_limit_rpm is set" do
      let(:rpm) { 2 }

      it "lets through calls below rpm" do
        redis = instance_double(Redis, incr: 1, expire: true)
        expect { described_class.new(redis: redis).throttle!(setting: setting) }.not_to raise_error
      end

      it "raises Rejected when the bucket is exhausted and max_wait_seconds elapses" do
        redis = instance_double(Redis)
        allow(redis).to receive(:incr).and_return(3)
        allow(redis).to receive(:expire).and_return(true)

        limiter = described_class.new(redis: redis)

        expect {
          limiter.throttle!(setting: setting, max_wait_seconds: 0.05)
        }.to raise_error(Ai::NvidiaRateLimiter::Rejected, /rate limit/)
      end

      it "fails open (allows the request) when Redis raises" do
        redis = instance_double(Redis)
        allow(redis).to receive(:incr).and_raise(Redis::BaseError, "down")

        limiter = described_class.new(redis: redis)

        expect { limiter.throttle!(setting: setting) }.not_to raise_error
      end
    end
  end
end
