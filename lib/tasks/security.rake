require "stringio"
require "yaml"

namespace :app do
  namespace :security do
    desc "Generate Active Record encryption keys and store them in encrypted credentials"
    task bootstrap_encryption: :environment do
      existing = Rails.application.credentials.dig(:active_record_encryption, :primary_key).present? &&
                 Rails.application.credentials.dig(:active_record_encryption, :deterministic_key).present? &&
                 Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt).present?

      if existing
        puts "Active Record encryption keys already exist in credentials. Skipping."
        next
      end

      generated_output = capture_stdout do
        Rake::Task["db:encryption:init"].reenable
        Rake::Task["db:encryption:init"].invoke
      end

      keys = parse_generated_keys(generated_output)
      update_credentials!(keys)

      puts "Stored Active Record encryption keys in encrypted credentials."
    end
  end
end

def capture_stdout
  old_stdout = $stdout
  io = StringIO.new
  $stdout = io
  yield
  io.string
ensure
  $stdout = old_stdout
end

def parse_generated_keys(output)
  {
    primary_key: output[/primary_key:\s+([A-Za-z0-9]+)/, 1],
    deterministic_key: output[/deterministic_key:\s+([A-Za-z0-9]+)/, 1],
    key_derivation_salt: output[/key_derivation_salt:\s+([A-Za-z0-9]+)/, 1]
  }.tap do |keys|
    if keys.values.any?(&:blank?)
      raise "Could not parse db:encryption:init output."
    end
  end
end

def update_credentials!(keys)
  encrypted_config = Rails.application.encrypted("config/credentials.yml.enc")
  current_data = YAML.safe_load(encrypted_config.read, aliases: true) || {}

  current_data["active_record_encryption"] ||= {}
  current_data["active_record_encryption"]["primary_key"] = keys[:primary_key]
  current_data["active_record_encryption"]["deterministic_key"] = keys[:deterministic_key]
  current_data["active_record_encryption"]["key_derivation_salt"] = keys[:key_derivation_salt]

  encrypted_config.write(current_data.to_yaml)
end
