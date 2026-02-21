require "rails_helper"

RSpec.describe ApplicationJob, type: :job do
  describe "job safety improvements" do
    it "includes JobSafetyImprovements module" do
      expect(ApplicationJob.included_modules).to include(JobSafetyImprovements)
    end

    it "includes JobIdempotency module" do
      expect(ApplicationJob.included_modules).to include(JobIdempotency)
    end

    it "includes EnhancedJobRetryStrategies module" do
      expect(ApplicationJob.included_modules).to include(EnhancedJobRetryStrategies)
    end
  end

  describe "error handling" do
    let(:job) { Class.new(ApplicationJob).new }

    it "categorizes authentication errors correctly" do
      error = Instagram::AuthenticationRequiredError.new("Auth required")
      expect(job.send(:authentication_error?, error)).to be true
    end

    it "categorizes transient errors correctly" do
      timeout_error = Net::ReadTimeout.new("Timeout")
      expect(job.send(:transient_error?, timeout_error)).to be true

      connection_error = Errno::ECONNRESET.new("Connection reset")
      expect(job.send(:transient_error?, connection_error)).to be true
    end

    it "determines retryable errors correctly" do
      auth_error = Instagram::AuthenticationRequiredError.new("Auth required")
      expect(job.send(:retryable_for, auth_error)).to be false

      timeout_error = Net::ReadTimeout.new("Timeout")
      expect(job.send(:retryable_for, timeout_error)).to be true

      invalid_payload_error = ArgumentError.new("invalid payload")
      expect(job.send(:retryable_for, invalid_payload_error)).to be false

      code_error = NoMethodError.new("undefined method `foo'")
      expect(job.send(:retryable_for, code_error)).to be false
    end
  end

  describe "failure kind classification" do
    let(:job) { Class.new(ApplicationJob).new }

    it "classifies authentication errors" do
      error = Instagram::AuthenticationRequiredError.new("Auth required")
      expect(job.send(:failure_kind_for, error)).to eq("authentication")
    end

    it "classifies transient errors" do
      error = Net::ReadTimeout.new("Timeout")
      expect(job.send(:failure_kind_for, error)).to eq("transient")
    end

    it "classifies runtime errors by default" do
      error = StandardError.new("Generic error")
      expect(job.send(:failure_kind_for, error)).to eq("runtime")
    end
  end

  describe "failure classification metadata helpers" do
    let(:job) { Class.new(ApplicationJob).new }

    it "marks manual review errors" do
      error = NoMethodError.new("undefined method")
      expect(job.send(:manual_review_required_for, error)).to be true
      expect(job.send(:failure_classification_for, error)).to eq("manual_review_required")
    end

    it "marks non-recoverable errors" do
      error = ActiveRecord::RecordNotFound.new("missing")
      expect(job.send(:failure_classification_for, error)).to eq("non_recoverable")
    end
  end

  describe "authentication backoff" do
    let(:account) { InstagramAccount.create!(username: "test_account", continuous_processing_state: "idle") }
    let(:job) { Class.new(ApplicationJob).new }
    let(:error) { Instagram::AuthenticationRequiredError.new("Auth required") }

    before do
      allow(job).to receive(:job_id).and_return(SecureRandom.uuid)
    end

    it "applies authentication backoff for account" do
      context = { instagram_account_id: account.id }
      
      # Verify initial state
      expect(account.continuous_processing_state).to eq("idle")
      
      job.send(:apply_auth_backoff!, context: context, error: error)
      
      # Should update failure count and retry time, but state remains idle
      updated_account = account.reload
      expect(updated_account.continuous_processing_state).to eq("idle")
      expect(updated_account.continuous_processing_failure_count).to eq(1)
      expect(updated_account.continuous_processing_last_error).to eq("Instagram::AuthenticationRequiredError: Auth required")
    end

    it "does not fail when account is not found" do
      context = { instagram_account_id: 99999 }
      
      expect do
        job.send(:apply_auth_backoff!, context: context, error: error)
      end.not_to raise_error
    end
  end

  describe "JSON serialization safety" do
    let(:job) { Class.new(ApplicationJob).new }

    it "handles serializable arguments" do
      args = [{ key: "value" }, 123, "string"]
      json = job.send(:safe_json, args)
      parsed = JSON.parse(json)
      expect(parsed).to eq([{"key" => "value"}, 123, "string"])
    end

    it "handles non-serializable arguments gracefully" do
      args = [Object.new]
      json = job.send(:safe_json, args)
      
      # The safe_json method should return a JSON string
      expect(json).to be_a(String)
      
      # Parse it and check the result
      parsed = JSON.parse(json)
      
      # In this Ruby version, JSON.generate doesn't fail for objects, it converts them to strings
      # So we expect the object to be serialized as a string representation
      expect(parsed).to be_an(Array)
      expect(parsed.first).to be_a(String)
      expect(parsed.first).to match(/#<Object:0x[0-9a-f]+>/)
    end
  end
end
