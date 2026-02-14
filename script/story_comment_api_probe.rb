require "json"
require "cgi"
require "time"

class StoryCommentApiProbe
  INSTAGRAM_BASE_URL = "https://www.instagram.com".freeze

  def initialize(account_id:, attempts: 2)
    @account = InstagramAccount.find(account_id)
    @client = Instagram::Client.new(account: @account)
    @attempts = attempts.to_i.clamp(1, 5)
  end

  def run!
    report = {
      generated_at: Time.current.utc.iso8601(3),
      account_id: @account.id,
      username: @account.username,
      attempts_requested: @attempts,
      attempts: []
    }

    @client.send(:with_authenticated_driver) do |driver|
      story_users = @client.send(:fetch_story_users_via_api).keys.first(10)
      raise "No story users found in reels tray API." if story_users.blank?

      story_users.each do |story_username|
        break if report[:attempts].length >= @attempts

        attempt = run_attempt(driver: driver, story_username: story_username, index: report[:attempts].length + 1)
        report[:attempts] << attempt
      end
    end

    report[:summary] = summarize(report[:attempts])
    write_report(report)
    print_summary(report)
    report
  end

  private

  def run_attempt(driver:, story_username:, index:)
    comment_text = "test api probe #{Time.current.utc.strftime('%Y%m%d%H%M%S')} ##{index}"

    driver.navigate.to("#{INSTAGRAM_BASE_URL}/stories/#{story_username}/")
    @client.send(:wait_for, driver, css: "body", timeout: 12)
    @client.send(:dismiss_common_overlays!, driver)
    @client.send(:freeze_story_progress!, driver)
    sleep(0.8)

    # Flush old performance log entries so we only inspect requests from this submission.
    begin
      driver.logs.get(:performance)
    rescue StandardError
      nil
    end

    before_ref = @client.send(:current_story_reference, driver.current_url.to_s)
    result = @client.send(:comment_on_story_via_ui!, driver: driver, comment_text: comment_text)
    sleep(2.0)

    perf_entries =
      begin
        driver.logs.get(:performance)
      rescue StandardError
        []
      end

    parsed = extract_relevant_requests(perf_entries)

    {
      index: index,
      story_username: story_username,
      story_reference: before_ref,
      comment_text: comment_text,
      ui_submit_result: result,
      relevant_request_count: parsed.length,
      relevant_requests: parsed
    }
  rescue StandardError => e
    {
      index: index,
      story_username: story_username,
      error_class: e.class.name,
      error_message: e.message
    }
  end

  def extract_relevant_requests(entries)
    request_index = {}
    response_index = {}
    headers_index = {}

    Array(entries).each do |entry|
      outer = parse_json(entry.message.to_s)
      inner = outer.is_a?(Hash) ? outer["message"] : nil
      next unless inner.is_a?(Hash)

      method = inner["method"].to_s
      params = inner["params"].is_a?(Hash) ? inner["params"] : {}
      request_id = params["requestId"].to_s

      case method
      when "Network.requestWillBeSent"
        req = params["request"].is_a?(Hash) ? params["request"] : {}
        request_index[request_id] = {
          method: req["method"].to_s,
          url: req["url"].to_s,
          post_data: req["postData"].to_s
        }
      when "Network.requestWillBeSentExtraInfo"
        headers = params["headers"].is_a?(Hash) ? params["headers"] : {}
        headers_index[request_id] = headers
      when "Network.responseReceived"
        response = params["response"].is_a?(Hash) ? params["response"] : {}
        response_index[request_id] = {
          status: response["status"].to_i,
          mime_type: response["mimeType"].to_s
        }
      end
    end

    rows = []
    request_index.each do |request_id, req|
      path = normalized_path(req[:url])
      next unless story_related_request?(path: path, headers: headers_index[request_id], post_data: req[:post_data])

      headers = headers_index[request_id] || {}
      identifiers = extract_identifiers(post_data: req[:post_data], path: path)

      rows << {
        request_id: request_id,
        http_method: req[:method],
        path: path,
        status: response_index.dig(request_id, :status),
        mime_type: response_index.dig(request_id, :mime_type),
        friendly_name: header_value(headers, "x-fb-friendly-name"),
        root_field: header_value(headers, "x-root-field-name"),
        doc_id: identifiers[:doc_id],
        variables: identifiers[:variables],
        id_hints: identifiers[:id_hints],
        key_payload_fields: identifiers[:key_payload_fields]
      }
    end

    rows
  end

  def summarize(attempts)
    requests = attempts.flat_map { |a| Array(a[:relevant_requests]) }
    by_path = requests.group_by { |r| r[:path] }.transform_values(&:length)
    by_friendly = requests.group_by { |r| r[:friendly_name].to_s }.transform_values(&:length)
    by_root = requests.group_by { |r| r[:root_field].to_s }.transform_values(&:length)

    {
      attempts_total: attempts.length,
      attempts_with_requests: attempts.count { |a| Array(a[:relevant_requests]).any? },
      request_total: requests.length,
      paths: by_path.sort_by { |_, v| -v }.to_h,
      friendly_names: by_friendly.sort_by { |_, v| -v }.to_h,
      root_fields: by_root.sort_by { |_, v| -v }.to_h
    }
  end

  def write_report(report)
    dir = Rails.root.join("tmp", "story_debug_reports")
    FileUtils.mkdir_p(dir)
    ts = Time.current.utc.strftime("%Y%m%dT%H%M%SZ")
    path = dir.join("story_comment_api_probe_#{ts}.json")
    File.write(path, JSON.pretty_generate(report))
    report[:report_path] = path.to_s
  end

  def print_summary(report)
    puts "Story comment API probe complete."
    puts "Account: #{report[:username]} (#{report[:account_id]})"
    puts "Attempts: #{report.dig(:summary, :attempts_total)}"
    puts "Attempts with relevant requests: #{report.dig(:summary, :attempts_with_requests)}"
    puts "Relevant requests total: #{report.dig(:summary, :request_total)}"
    puts "Top paths:"
    report.dig(:summary, :paths).to_h.first(10).each { |path, count| puts "  #{count}  #{path}" }
    puts "Top friendly names:"
    report.dig(:summary, :friendly_names).to_h.first(10).each { |name, count| puts "  #{count}  #{name}" }
    puts "Top root fields:"
    report.dig(:summary, :root_fields).to_h.first(10).each { |name, count| puts "  #{count}  #{name}" }
    puts "Report: #{report[:report_path]}"
  end

  def story_related_request?(path:, headers:, post_data:)
    value = [ path.to_s, post_data.to_s, header_value(headers, "x-fb-friendly-name"), header_value(headers, "x-root-field-name") ].join(" ").downcase
    value.include?("story") || value.include?("reel")
  end

  def extract_identifiers(post_data:, path:)
    ids = post_data.to_s.scan(/\b\d{8,}\b/).uniq.first(30)
    parsed = CGI.parse(post_data.to_s)
    friendly = parsed["fb_api_req_friendly_name"]&.first.to_s
    doc_id = parsed["doc_id"]&.first.to_s.presence
    vars = parse_json(parsed["variables"]&.first.to_s)

    key_fields = {}
    parsed.each do |k, v|
      next unless k.match?(/(reel|story|media|user|thread|target|recipient|id)/i)
      key_fields[k] = v.first.to_s.byteslice(0, 500)
    end
    key_fields["fb_api_req_friendly_name"] = friendly if friendly.present?

    {
      doc_id: doc_id,
      variables: vars,
      id_hints: ids,
      key_payload_fields: key_fields
    }
  rescue StandardError
    { doc_id: nil, variables: nil, id_hints: [], key_payload_fields: {} }
  end

  def normalized_path(url)
    uri = URI.parse(url.to_s)
    path = uri.path.to_s
    query = uri.query.to_s
    query.present? ? "#{path}?#{query}" : path
  rescue StandardError
    url.to_s
  end

  def header_value(headers, key)
    return "" unless headers.is_a?(Hash)
    headers[key].to_s.presence ||
      headers[key.downcase].to_s.presence ||
      headers[key.upcase].to_s.presence ||
      ""
  end

  def parse_json(raw)
    JSON.parse(raw)
  rescue StandardError
    nil
  end
end

account_id = ENV.fetch("ACCOUNT_ID", "2").to_i
attempts = ENV.fetch("ATTEMPTS", "2").to_i

StoryCommentApiProbe.new(account_id: account_id, attempts: attempts).run!
