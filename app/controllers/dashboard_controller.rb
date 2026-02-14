class DashboardController < ApplicationController
  before_action :require_current_account!

  def index
    @account = current_account
    @recipients = @account.recipients.order(Arel.sql("can_message DESC, selected DESC, username ASC"))
    @eligible_count = @account.recipients.eligible.count
    @selected_count = @account.recipients.selected.count
  end
end
