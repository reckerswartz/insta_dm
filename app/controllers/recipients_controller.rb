class RecipientsController < ApplicationController
  before_action :require_current_account!

  def update_all
    selected_ids = Array(params[:selected_ids]).map(&:to_i)
    scope = current_account.recipients

    scope.update_all(selected: false)
    scope.where(id: selected_ids).update_all(selected: true)

    redirect_to root_path, notice: "Recipient selections updated."
  end
end
