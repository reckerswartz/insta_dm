require "net/http"
require "json"

class CheckAiMicroserviceHealthJob < ApplicationJob
  queue_as :sync

  def perform
    health = Ops::LocalAiHealth.check(force: true)
    ok = ActiveModel::Type::Boolean.new.cast(health[:ok])

    message =
      if ok
        "Local AI stack healthy"
      else
        "Local AI stack unhealthy"
      end

    Ops::IssueTracker.record_ai_service_check!(
      ok: ok,
      message: message,
      metadata: health
    )
  rescue StandardError => e
    Ops::IssueTracker.record_ai_service_check!(
      ok: false,
      message: "AI microservice health check failed: #{e.message}",
      metadata: { error_class: e.class.name }
    )
    raise
  end
end
