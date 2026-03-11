source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Hotwire (Turbo Streams for background job notifications + fast UI updates)
gem "turbo-rails"
gem "stimulus-rails"
# PostgreSQL database adapter
gem "pg", "~> 1.5"
gem "pgvector", "~> 0.3"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
gem "webrick"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background jobs
gem "sidekiq", "~> 7.3"
gem "sidekiq-cron", "~> 2.3"
gem "redis", "~> 5.3"
# Sidekiq 7.3.x is not compatible with connection_pool 3.x keyword-only pop API.
gem "connection_pool", ">= 2.5.0", "< 3.0"

# Keep Mission Control dashboard for job visibility
gem "mission_control-jobs"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
gem "ruby-vips", "~> 2.2", require: false
gem "selenium-webdriver", "~> 4.41"
gem "aws-sdk-rekognition", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :test do
  gem "parallel_tests", "~> 4.0"
  gem "rspec-rails", "~> 8.0"
  gem "simplecov", "~> 0.22", require: false
  gem "vcr", "~> 6.3"
  gem "webmock", "~> 3.23"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  # gem 'web-console'
end

gem "jsbundling-rails", "~> 1.3"

gem "cssbundling-rails", "~> 1.4"
