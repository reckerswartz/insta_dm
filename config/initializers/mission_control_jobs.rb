# Mission Control's `config.mission_control.jobs.*` options are applied during
# engine `before_initialize`, so setting them in an app initializer is too late.
# Configure runtime flags directly here to ensure auth is disabled.
MissionControl::Jobs.base_controller_class = "::ApplicationController"
MissionControl::Jobs.http_basic_auth_enabled = false
