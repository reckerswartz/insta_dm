# frozen_string_literal: true

module LlmComment
  # Service for preparing profile context for LLM comment generation
  # Extracted from GenerateLlmCommentJob to follow Single Responsibility Principle
  class ProfileContextPreparationService
    include ActiveModel::Validations

    attr_reader :account, :profile, :preparation_result

    def initialize(profile:, account:)
      @profile = profile
      @account = account
    end

    def prepare!
      return failure_response("profile_missing", "Profile missing for event.") unless profile && account

      @preparation_result = Ai::ProfileCommentPreparationService.new(
        account: account,
        profile: profile
      ).prepare!

      @preparation_result
    rescue StandardError => e
      failure_response("profile_preparation_error", e.message, e.class.name)
    end

    private

    def failure_response(reason_code, reason, error_class = nil)
      {
        ready_for_comment_generation: false,
        reason_code: reason_code,
        reason: reason,
        error_class: error_class
      }
    end
  end
end
