# frozen_string_literal: true

namespace :ai do
  namespace :nvidia do
    desc "Validate the NVIDIA api_key by calling /v1/models for each enabled role row"
    task test_key: :environment do
      Ai::ProviderRegistry.ensure_settings!
      rows = AiProviderSetting.for_provider("nvidia").where(enabled: true).order(:role)

      if rows.none?
        abort "No enabled nvidia provider rows. Enable rows (e.g. AiProviderSetting.for_provider('nvidia').update_all(enabled: true)) or configure them via the admin UI."
      end

      rows.each do |row|
        unless row.api_key_present?
          puts format("- %-16s SKIP  (no api_key; Rails credentials may be missing :nvidia :api_key)", row.role)
          next
        end

        begin
          client = Ai::NvidiaClient.new(setting: row, max_retries: 1)
          result = client.list_models!
          count = Array(result["data"]).length
          puts format("- %-16s OK    model=%-50s models_available=%d", row.role, row.effective_model, count)
        rescue Ai::NvidiaClient::AuthError => e
          puts format("- %-16s AUTH  %s", row.role, e.message[0, 160])
          exit(1)
        rescue StandardError => e
          puts format("- %-16s FAIL  %s: %s", row.role, e.class, e.message[0, 160])
          exit(1)
        end
      end

      puts "All enabled nvidia rows authenticated successfully."
    end

    desc "Run a tiny chat completion + embedding round-trip against the default NVIDIA roles"
    task smoke: :environment do
      Ai::ProviderRegistry.ensure_settings!
      provider = Ai::ProviderRegistry.build_provider("nvidia")

      print "chat (text_quality): "
      puts provider.chat!(
        role: "text_quality",
        messages: [{ role: "user", content: "Reply with exactly: OK" }],
        temperature: 0.1,
        max_tokens: 8
      ).dig("choices", 0, "message", "content").to_s.strip.inspect

      print "embedding: "
      dim = provider.embed!(input: "hello", extra: { input_type: "query" })
                    .dig("data", 0, "embedding").to_a.length
      puts "#{dim}-dimensional vector"
    end
  end
end
