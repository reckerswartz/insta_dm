Rails.application.configure do
  # Keep Mission Control open for now (no auth) to simplify setup/troubleshooting.
  config.mission_control.jobs.base_controller_class = "ApplicationController"
  config.mission_control.jobs.http_basic_auth_enabled = false
end
