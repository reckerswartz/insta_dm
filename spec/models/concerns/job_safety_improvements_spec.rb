require "rails_helper"

RSpec.describe JobSafetyImprovements, type: :model do
  let(:test_job_class) do
    Class.new(ApplicationJob) do
      def self.name
        "TestJob"
      end
    end
  end

  describe ".safe_find_record" do
    let!(:account) { InstagramAccount.create!(username: "test_account") }

    it "returns an existing record" do
      expect(test_job_class.safe_find_record(InstagramAccount, account.id)).to eq(account)
    end

    it "returns nil and logs when record is missing" do
      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.record_not_found",
        payload: hash_including(job_class: "TestJob", record_class: "InstagramAccount", record_id: 99999)
      )

      expect(test_job_class.safe_find_record(InstagramAccount, 99999)).to be_nil
    end
  end

  describe ".safe_find_chain" do
    let!(:account) { InstagramAccount.create!(username: "test_account_chain") }
    let!(:profile) { InstagramProfile.create!(username: "test_profile", instagram_account: account) }

    it "returns associated record" do
      expect(test_job_class.safe_find_chain(account, :instagram_profiles, profile.id)).to eq(profile)
    end

    it "logs when associated record is missing" do
      expect(Ops::StructuredLogger).to receive(:warn).with(
        event: "job.association_record_not_found",
        payload: hash_including(
          job_class: "TestJob",
          parent_class: "InstagramAccount",
          association: :instagram_profiles,
          record_id: 99999
        )
      )

      expect(test_job_class.safe_find_chain(account, :instagram_profiles, 99999)).to be_nil
    end
  end

  describe "instance helpers" do
    let(:job) { test_job_class.new }

    describe "#safe_method_call" do
      let(:target_object) { double("target") }

      it "returns nil for unknown methods" do
        expect(job.send(:safe_method_call, target_object, :missing_method)).to be_nil
      end

      it "logs and re-raises method errors" do
        allow(target_object).to receive(:failing_method).and_raise(StandardError.new("Method failed"))

        expect(Ops::StructuredLogger).to receive(:error).with(
          event: "job.method_call_error",
          payload: hash_including(job_class: "TestJob", method_name: :failing_method, error_class: "StandardError")
        )

        expect { job.send(:safe_method_call, target_object, :failing_method) }.to raise_error(StandardError, "Method failed")
      end
    end

    describe "#validate_job_arguments!" do
      it "passes when required keys are present" do
        allow(job).to receive(:arguments).and_return([{ "account_id" => 1, "profile_id" => 2 }])

        expect { job.send(:validate_job_arguments!, %i[account_id profile_id]) }.not_to raise_error
      end

      it "raises when required keys are missing" do
        allow(job).to receive(:arguments).and_return([{ "account_id" => 1 }])

        expect { job.send(:validate_job_arguments!, %i[account_id profile_id]) }
          .to raise_error(ArgumentError, /Missing required job arguments: profile_id/)
      end

      it "logs unexpected keys" do
        allow(job).to receive(:arguments).and_return([{ "account_id" => 1, "profile_id" => 2, "unexpected" => true }])

        expect(Ops::StructuredLogger).to receive(:warn).with(
          event: "job.unexpected_arguments",
          payload: hash_including(job_class: "TestJob", unexpected_keys: include("unexpected"))
        )

        job.send(:validate_job_arguments!, %i[account_id profile_id])
      end
    end

    describe "#arguments_hash" do
      it "returns first argument hash" do
        allow(job).to receive(:arguments).and_return([{ "key" => "value" }])
        expect(job.send(:arguments_hash)).to eq({ "key" => "value" })
      end

      it "returns empty hash for malformed arguments" do
        allow(job).to receive(:arguments).and_return(nil)
        expect(job.send(:arguments_hash)).to eq({})
      end
    end
  end

  describe "registered handlers" do
    it "registers expected discard/retry handlers on ApplicationJob" do
      handlers = ApplicationJob.send(:rescue_handlers).map(&:first)

      expect(handlers).to include(
        "ActiveRecord::RecordNotFound",
        "Instagram::AuthenticationRequiredError",
        "ActiveRecord::ConnectionTimeoutError",
        "Net::ReadTimeout",
        "Errno::ECONNRESET"
      )
    end
  end
end
