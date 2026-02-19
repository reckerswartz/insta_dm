require "vcr"
require "webmock/rspec"

record_mode = ENV.fetch("VCR_RECORD_MODE", ENV["CI"] ? "none" : "once").to_sym
cassette_scope = ENV.fetch("VCR_CASSETTE_SCOPE", Rails.env)

VCR.configure do |config|
  config.cassette_library_dir = Rails.root.join("spec", "vcr_cassettes", cassette_scope).to_s
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.ignore_localhost = true
  config.allow_http_connections_when_no_cassette = ENV["VCR_ALLOW_HTTP_WITHOUT_CASSETTE"] == "true"

  config.default_cassette_options = {
    record: record_mode,
    match_requests_on: %i[method uri body]
  }

  config.filter_sensitive_data("<INSTAGRAM_SESSIONID>") { ENV["INSTAGRAM_SESSIONID"] }
  config.filter_sensitive_data("<OLLAMA_API_KEY>") { ENV["OLLAMA_API_KEY"] }
  config.filter_sensitive_data("<OPENAI_API_KEY>") { ENV["OPENAI_API_KEY"] }
  config.filter_sensitive_data("<OFFICIAL_MESSAGING_API_TOKEN>") { ENV["OFFICIAL_MESSAGING_API_TOKEN"] }
  config.filter_sensitive_data("<OFFICIAL_MESSAGING_API_TOKEN>") { "test_token" }
end

WebMock.disable_net_connect!(allow_localhost: true) unless ENV["VCR_ALLOW_HTTP_WITHOUT_CASSETTE"] == "true"
