require "rails_helper"
require "securerandom"

RSpec.describe ApplicationJob do
  it "applies continuous-processing backoff when authentication is required" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    stub_const("AuthDiscardProbeJob", Class.new(ApplicationJob) do
      queue_as :default

      def perform(instagram_account_id:)
        raise Instagram::AuthenticationRequiredError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
      end
    end)

    expect do
      AuthDiscardProbeJob.perform_now(instagram_account_id: account.id)
    end.not_to raise_error

    account.reload
    expect(account.continuous_processing_state).to eq("idle")
    expect(account.continuous_processing_failure_count.to_i).to eq(1)
    expect(account.continuous_processing_retry_after_at).to be_present
    expect(account.continuous_processing_retry_after_at).to be > Time.current
    expect(account.continuous_processing_last_error).to include("Instagram::AuthenticationRequiredError")
  end
end
