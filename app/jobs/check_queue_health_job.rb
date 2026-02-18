class CheckQueueHealthJob < ApplicationJob
  queue_as :sync

  def perform
    Ops::QueueHealth.check!
  end
end
