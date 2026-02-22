require "fileutils"
require "json"
require "rails_helper"
require "time"

RSpec.describe "UI Story Comment Benchmark", :diagnostic, :slow, :external_app, :diagnostic_ui, :ui_workflow do
  COMPLETE_TIMEOUT_SECONDS = Integer(ENV.fetch("UI_AUDIT_COMMENT_COMPLETE_TIMEOUT_SECONDS", "420"))

  it "captures end-to-end story comment generation benchmark metrics" do |example|
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
      click_with_fallback(driver: driver, element: load_button) if load_button&.enabled?

      preferred_event_id = ENV.fetch("UI_AUDIT_EVENT_ID", "").to_s.strip
      card = select_story_card(driver, preferred_event_id: preferred_event_id)
      if card.nil?
        strict = ENV.fetch("UI_AUDIT_REQUIRE_STORY_CARD", "0") == "1"
        expect(strict).to eq(false), "No story archive cards found. Seed archive data or set UI_AUDIT_STORY_ACCOUNT_PATH."
        next
      end

      view_button = card.find_elements(css: "button[data-action='click->story-media-archive#openStoryModal']").find(&:displayed?)
      expect(view_button).to be_present
      click_with_fallback(driver: driver, element: view_button)

      wait_for_selector(driver, css: ".story-modal-overlay .story-modal", timeout: 12)
      modal = driver.find_element(css: ".story-modal-overlay .story-modal")
      generate_button = modal.find_elements(css: ".generate-comment-btn").find(&:displayed?)
      expect(generate_button).to be_present

      force_regenerate = ENV.fetch("UI_AUDIT_FORCE_REGENERATE", "1") == "1"
      if force_regenerate
        driver.execute_script("arguments[0].dataset.generateForce = 'true';", generate_button)
      end

      event_id = extract_event_id(card: card, button: generate_button)
      expect(event_id).to be_present

      started_at_utc = Time.now.utc
      started_monotonic = monotonic_now
      click_with_fallback(driver: driver, element: generate_button)

      wait_for_generation_completion(driver, timeout: COMPLETE_TIMEOUT_SECONDS)

      finished_at_utc = Time.now.utc
      finished_monotonic = monotonic_now
      elapsed_seconds = (finished_monotonic - started_monotonic).round(3)
      probe = read_workflow_probe(driver)
      final_status = extract_modal_status(driver)

      server_metrics = collect_server_metrics(event_id: event_id)
      metrics = {
        captured_at: Time.now.utc.iso8601(3),
        account_path: account_path,
        event_id: event_id.to_i,
        started_at_utc: started_at_utc.iso8601(3),
        completed_at_utc: finished_at_utc.iso8601(3),
        ui_click_to_complete_seconds: elapsed_seconds,
        trigger_api_calls: probe.dig("generateRequests", "triggerCalls").to_i,
        status_poll_calls: probe.dig("generateRequests", "statusCalls").to_i,
        final_status: final_status
      }.merge(server_metrics)

      comparison = compare_against_baseline(metrics)
      metrics[:comparison] = comparison if comparison.is_a?(Hash) && comparison.any?
      artifact_path = write_benchmark_artifact(metrics)

      puts "\nStory comment benchmark artifact: #{artifact_path}"
      puts JSON.pretty_generate(metrics)

      expect(metrics[:trigger_api_calls]).to eq(1), "Expected one generate trigger API call, got #{metrics[:trigger_api_calls]}"
      expect(metrics[:final_status].to_s.downcase).to include("completed")
    end
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def select_story_card(driver, preferred_event_id:)
    if preferred_event_id.present?
      exact = driver.find_elements(css: ".story-media-card[data-event-id='#{preferred_event_id}']").find(&:displayed?)
      return exact if exact
    end

    driver.find_elements(css: ".story-media-card").find(&:displayed?)
  end

  def extract_event_id(card:, button:)
    button_event_id = button.attribute("data-event-id").to_s.strip
    return button_event_id if button_event_id.present?

    card.attribute("data-event-id").to_s.strip
  rescue StandardError
    ""
  end

  def wait_for_generation_completion(driver, timeout:)
    Selenium::WebDriver::Wait.new(timeout: timeout).until do
      status_done = driver.find_elements(css: ".story-modal-overlay [data-role='llm-status']").any? do |node|
        node.displayed? && node.text.to_s.strip.casecmp("completed").zero?
      end
      button_done = driver.find_elements(css: ".story-modal-overlay .generate-comment-btn").any? do |node|
        node.displayed? && node.enabled? && node.text.to_s.match?(/regenerate/i)
      end
      status_done || button_done
    end
  end

  def extract_modal_status(driver)
    status_node = driver.find_elements(css: ".story-modal-overlay [data-role='llm-status']").find(&:displayed?)
    text = status_node&.text.to_s.strip
    return text if text.present?

    button = driver.find_elements(css: ".story-modal-overlay .generate-comment-btn").find(&:displayed?)
    return "completed" if button&.text.to_s.match?(/regenerate/i)

    "unknown"
  rescue StandardError
    "unknown"
  end

  def click_with_fallback(driver:, element:)
    return unless element

    element.click
  rescue Selenium::WebDriver::Error::ElementClickInterceptedError, Selenium::WebDriver::Error::ElementNotInteractableError
    driver.execute_script("arguments[0].click();", element)
  end

  def collect_server_metrics(event_id:)
    event = InstagramProfileEvent.find_by(id: event_id.to_i)
    return {} unless event

    llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
    telemetry = llm_meta["llm_telemetry"].is_a?(Hash) ? llm_meta["llm_telemetry"] : {}
    pipeline = llm_meta["parallel_pipeline"].is_a?(Hash) ? llm_meta["parallel_pipeline"] : {}
    run_id = pipeline["run_id"].to_s.presence
    details = pipeline["details"].is_a?(Hash) ? pipeline["details"] : {}

    log_rollup = summarize_pipeline_logs(event_id: event.id, run_id: run_id)

    {
      llm_comment_status_db: event.llm_comment_status.to_s,
      pipeline_run_id: run_id,
      prompt_chars: llm_meta["prompt"].to_s.length,
      prompt_eval_count: telemetry["prompt_eval_count"].to_i,
      eval_count: telemetry["eval_count"].to_i,
      ollama_total_duration_seconds: nanos_to_seconds(telemetry["total_duration_ns"]),
      ollama_load_duration_seconds: nanos_to_seconds(telemetry["load_duration_ns"]),
      pipeline_duration_ms: details["pipeline_duration_ms"],
      pipeline_generation_duration_ms: details["generation_duration_ms"]
    }.merge(log_rollup)
  end

  def summarize_pipeline_logs(event_id:, run_id:)
    rows = read_structured_log_rows
    scoped = rows.select do |row|
      row["event"].to_s.start_with?("llm_comment.pipeline.") &&
        row["event_id"].to_i == event_id.to_i &&
        (run_id.to_s.blank? || row["pipeline_run_id"].to_s == run_id.to_s)
    end

    counts = scoped.group_by { |row| row["event"].to_s }.transform_values(&:length)
    {
      finalizer_enqueued_count: counts["llm_comment.pipeline.finalizer_enqueued"].to_i,
      finalizer_executed_count: %w[
        llm_comment.pipeline.finalizer_waiting
        llm_comment.pipeline.finalizer_skipped_terminal
        llm_comment.pipeline.generation_worker_queued
        llm_comment.pipeline.failed
      ].sum { |event_key| counts[event_key].to_i },
      generation_worker_queued_count: counts["llm_comment.pipeline.generation_worker_queued"].to_i,
      pipeline_completed_count: counts["llm_comment.pipeline.completed"].to_i
    }
  end

  def read_structured_log_rows
    log_path = ENV.fetch("UI_AUDIT_LOG_PATH", Rails.root.join("log/development.log").to_s)
    return [] unless File.exist?(log_path)

    rows = []
    File.foreach(log_path) do |line|
      index = line.index("{")
      next unless index

      payload = line[index..]
      parsed = JSON.parse(payload)
      rows << parsed if parsed.is_a?(Hash) && parsed["event"].to_s.start_with?("llm_comment.")
    rescue JSON::ParserError
      next
    end
    rows
  rescue StandardError
    []
  end

  def nanos_to_seconds(value)
    raw = value.to_i
    return nil if raw <= 0

    (raw / 1_000_000_000.0).round(3)
  end

  def compare_against_baseline(current_metrics)
    baseline_path = ENV.fetch("UI_AUDIT_BENCHMARK_BASELINE_FILE", "").to_s.strip
    return {} if baseline_path.empty? || !File.exist?(baseline_path)

    baseline = JSON.parse(File.read(baseline_path))
    return {} unless baseline.is_a?(Hash)

    compare_numeric = %w[
      ui_click_to_complete_seconds
      status_poll_calls
      prompt_chars
      prompt_eval_count
      ollama_total_duration_seconds
      pipeline_generation_duration_ms
      finalizer_enqueued_count
      finalizer_executed_count
    ]

    compare_numeric.each_with_object({ baseline_file: baseline_path }) do |key, out|
      old_value = baseline[key]
      new_value = current_metrics[key.to_sym]
      next unless old_value.is_a?(Numeric) && new_value.is_a?(Numeric)

      delta = (new_value - old_value).round(3)
      pct = old_value.to_f.zero? ? nil : ((delta / old_value.to_f) * 100.0).round(2)
      out[key] = {
        baseline: old_value,
        current: new_value,
        delta: delta,
        delta_pct: pct
      }
    end
  rescue StandardError
    {}
  end

  def write_benchmark_artifact(metrics)
    output_dir = Rails.root.join("tmp/diagnostic_specs/story_comment_benchmark")
    FileUtils.mkdir_p(output_dir)
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    event_id = metrics[:event_id].to_i
    path = output_dir.join("#{timestamp}_event_#{event_id}.json")
    File.write(path, JSON.pretty_generate(metrics))
    path.to_s
  end
end
