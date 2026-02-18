require "net/http"
require "json"

class CheckAiMicroserviceHealthJob < ApplicationJob
  queue_as :sync

  HEALTH_URL = URI.parse("http://localhost:8000/health")

  def perform
    response = Net::HTTP.get_response(HEALTH_URL)
    ok = response.code.to_s == "200"

    payload = {}
    if ok
      payload = JSON.parse(response.body) rescue {}
    end

    message =
      if ok
        "AI microservice healthy"
      else
        "AI microservice unhealthy (HTTP #{response.code})"
      end

    Ops::IssueTracker.record_ai_service_check!(
      ok: ok,
      message: message,
      metadata: {
        http_status: response.code.to_i,
        response_body_preview: response.body.to_s.byteslice(0, 300),
        services: payload["services"]
      }
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
