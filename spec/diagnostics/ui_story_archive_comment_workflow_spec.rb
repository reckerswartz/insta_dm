require "rails_helper"

RSpec.describe "UI Story Archive Comment Workflow", :diagnostic, :slow, :external_app, :diagnostic_ui, :ui_workflow do
  it "keeps comment generation state stable and avoids duplicate trigger calls" do |example|
    next unless ensure_ui_audit_server!

    account_path = resolve_story_account_path
    if account_path.to_s.empty?
      strict = ENV.fetch("UI_AUDIT_REQUIRE_STORY_ACCOUNT_PATH", "0") == "1"
      expect(strict).to eq(false), "Unable to discover an account path. Set UI_AUDIT_STORY_ACCOUNT_PATH=/instagram_accounts/:id"
      next
    end

    with_workflow_driver(example) do |driver|
      driver.navigate.to(URI.join(ui_workflow_base_url, account_path).to_s)
      wait_for_dom_ready(driver, timeout: 20)
      inject_workflow_probe(driver)

      load_button = driver.find_elements(css: "[data-story-media-archive-target='loadButton']").find(&:displayed?)
      load_button&.click

      cards = driver.find_elements(css: ".story-media-card")
      if cards.empty?
        strict = ENV.fetch("UI_AUDIT_REQUIRE_STORY_CARD", "0") == "1"
        expect(strict).to eq(false), "No story archive cards found. Seed archive data or set UI_AUDIT_STORY_ACCOUNT_PATH."
        next
      end

      view_button = cards.first.find_elements(css: "button[data-action='click->story-media-archive#openStoryModal']").find(&:displayed?)
      expect(view_button).to be_present
      view_button.click

      wait_for_selector(driver, css: ".story-modal-overlay .story-modal", timeout: 12)
      modal = driver.find_element(css: ".story-modal-overlay .story-modal")
      existing_suggestion = modal.find_elements(css: ".llm-generated-comment").find(&:displayed?)
      next if existing_suggestion

      generate_button = modal.find_elements(css: ".generate-comment-btn").find(&:displayed?)
      expect(generate_button).to be_present

      # Simulate rapid user re-clicks; trigger calls should still be deduplicated.
      2.times { generate_button.click }

      wait_for_text(
        driver,
        css: ".story-modal-overlay .generate-comment-btn",
        pattern: /(Queued|Generating|Completed|Generate Comment Locally)/i,
        timeout: 12
      )

      button_state = driver.find_element(css: ".story-modal-overlay .generate-comment-btn")
      label = button_state.text.to_s
      disabled = !button_state.enabled?

      probe = read_workflow_probe(driver)
      trigger_calls = probe.dig("generateRequests", "triggerCalls").to_i
      expect(trigger_calls).to eq(1), "Expected one trigger call, got #{trigger_calls} (probe=#{probe.inspect})"

      # If the button re-enables quickly, the UI must provide an explicit state/error hint.
      if !disabled && label.match?(/generate comment locally/i)
        hints = driver.find_elements(css: ".story-modal-overlay .llm-progress-hint, .story-modal-overlay .error-text").map { |node| node.text.to_s.strip }.reject(&:empty?)
        expect(hints).not_to be_empty, "Button reset to ready state without any progress/error hint."
      end

      failures = Array(probe["failedRequests"]).select do |row|
        row.is_a?(Hash) && row["url"].to_s.include?("/generate_llm_comment") && row["status"].to_i >= 500
      end
      expect(failures).to eq([]), "Observed generate_llm_comment 5xx responses: #{failures.inspect}"
    end
  end
end
