require "rails_helper"
require "securerandom"

RSpec.describe "InstagramAccounts destroy", type: :request do
  it "surfaces cleanup errors when deletion is aborted" do
    account = InstagramAccount.create!(username: "acct_destroy_#{SecureRandom.hex(4)}")
    allow_any_instance_of(InstagramAccounts::AccountDeletionCleanupService)
      .to receive(:call)
      .and_raise(
        InstagramAccounts::AccountDeletionCleanupService::CleanupError,
        "Cannot delete account while 1 job(s) are still running for this account."
      )

    expect do
      delete instagram_account_path(account)
    end.not_to change(InstagramAccount, :count)

    expect(response).to redirect_to(instagram_account_path(account))
    expect(flash[:alert]).to include("Unable to remove account:")
    expect(flash[:alert]).to include("still running for this account")
  end
end
