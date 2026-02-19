class WorkspacesController < ApplicationController
  include ProfilePostPreviewSupport

  before_action :require_current_account!

  DEFAULT_QUEUE_LIMIT = 40

  def actions
    @account = resolved_account
    @queue_result = load_queue_result(account: @account)
  end

  def actions_feed
    account = resolved_account
    queue_result = load_queue_result(account: account)

    render partial: "workspaces/actions_queue_section", locals: { account: account, queue_result: queue_result }
  rescue StandardError => e
    render html: view_context.content_tag(:p, "Unable to refresh workspace queue: #{e.message}", class: "meta"), status: :unprocessable_entity
  end

  private

  def resolved_account
    requested_id = params[:instagram_account_id].to_i
    return current_account if requested_id <= 0

    current_account.id == requested_id ? current_account : current_account.class.find(requested_id)
  rescue StandardError
    current_account
  end

  def load_queue_result(account:)
    Workspace::ActionsTodoQueueService.new(
      account: account,
      limit: params.fetch(:limit, DEFAULT_QUEUE_LIMIT),
      enqueue_processing: true
    ).fetch!
  end
end
