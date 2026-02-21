class ReevaluateProfileContentJob < ApplicationJob
  queue_as :profile_reevaluation

  def perform(instagram_account_id:, instagram_profile_id:, content_type:, content_id:)
    account = InstagramAccount.find_by(id: instagram_account_id)
    profile = InstagramProfile.find_by(id: instagram_profile_id, instagram_account_id: instagram_account_id)
    return unless account && profile

    ProfileReevaluationService.new(account: account, profile: profile)
      .reevaluate_after_content_scan!(content_type: content_type, content_id: content_id)
  end
end
