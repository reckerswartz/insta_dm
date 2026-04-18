module Instagram
  module Browser
    # Thin per-page accumulator that captures the data Selenium exposed via
    # `driver.logs.get(:browser)` / `driver.logs.get(:performance)` but that
    # Playwright only emits as events. Wire it up once when a Page is
    # created; Instagram::Client::TaskCaptureSupport reads its buffers
    # whenever a task capture artifact is written.
    #
    # Usage:
    #   page = context.new_page
    #   Instagram::Browser::PageInstrumentation.attach!(page)
    #   ...
    #   page.instrumentation.console_entries.last(10)
    #   page.instrumentation.network_entries.last(10)
    #
    # Buffers are bounded so a long-running page does not grow without
    # limit. Oldest entries are evicted first.
    class PageInstrumentation
      DEFAULT_CONSOLE_CAP = 400
      DEFAULT_NETWORK_CAP = 800

      # Installs listeners on `page` and hangs a `.instrumentation` reader
      # on it. Subsequent calls on the same page are no-ops.
      def self.attach!(page, console_cap: DEFAULT_CONSOLE_CAP, network_cap: DEFAULT_NETWORK_CAP)
        return page.instrumentation if page.respond_to?(:instrumentation) && page.instrumentation

        instance = new(page: page, console_cap: console_cap, network_cap: network_cap)
        instance.send(:install_listeners!)

        # define_singleton_method works on Playwright objects -- they are
        # plain Ruby objects wrapping the Node-side Page channel.
        ref = instance
        page.define_singleton_method(:instrumentation) { ref }
        instance
      end

      attr_reader :console_entries, :network_entries

      def initialize(page:, console_cap: DEFAULT_CONSOLE_CAP, network_cap: DEFAULT_NETWORK_CAP)
        @page = page
        @console_entries = []
        @network_entries = []
        @console_cap = console_cap.to_i
        @network_cap = network_cap.to_i
        @mutex = Mutex.new
      end

      # Returns the same shape Selenium's browser log entries had, so
      # TaskCaptureSupport can treat both the same way.
      def selenium_shaped_browser_entries
        @mutex.synchronize { @console_entries.dup }
      end

      # Returns Chrome-DevTools-shaped performance log entries. We wrap our
      # events in the same `{ "message" => "<json>" }` envelope Selenium
      # used so summarize_performance_logs / filter_performance_logs can
      # consume them unchanged.
      def selenium_shaped_performance_entries
        @mutex.synchronize { @network_entries.map { |e| wrap_as_chrome_perf_entry(e) } }
      end

      private

      def install_listeners!
        @page.on("console", method(:handle_console))
        @page.on("request", method(:handle_request))
        @page.on("response", method(:handle_response))
        @page.on("requestfailed", method(:handle_request_failed))
      rescue StandardError
        # Listeners are best-effort. If the page is already detached we
        # leave the buffers empty.
      end

      def handle_console(message)
        push_console(
          timestamp: (Time.current.to_f * 1000).to_i,
          level: message.type.to_s.upcase,
          message: safe_message_text(message)
        )
      rescue StandardError
        # ignore
      end

      def handle_request(request)
        push_network(
          kind: "Network.requestWillBeSent",
          timestamp: (Time.current.to_f * 1000).to_i,
          request_id: request.respond_to?(:url) ? (request.object_id.to_s) : nil,
          request: {
            "url" => safe_url(request),
            "method" => safe_method(request)
          }
        )
      rescue StandardError
        # ignore
      end

      def handle_response(response)
        req = begin
          response.request
        rescue StandardError
          nil
        end

        push_network(
          kind: "Network.responseReceived",
          timestamp: (Time.current.to_f * 1000).to_i,
          request_id: req ? req.object_id.to_s : nil,
          response: {
            "url" => safe_url(response),
            "status" => (response.status rescue nil),
            "mimeType" => response.respond_to?(:headers) ? (response.headers["content-type"] rescue nil) : nil
          }
        )
      rescue StandardError
        # ignore
      end

      def handle_request_failed(request)
        push_network(
          kind: "Network.loadingFailed",
          timestamp: (Time.current.to_f * 1000).to_i,
          request_id: request.object_id.to_s,
          request: { "url" => safe_url(request), "method" => safe_method(request) },
          failure: begin
            request.failure.to_s
          rescue StandardError
            nil
          end
        )
      rescue StandardError
        # ignore
      end

      def push_console(entry)
        @mutex.synchronize do
          @console_entries << entry
          trim!(@console_entries, @console_cap)
        end
      end

      def push_network(entry)
        @mutex.synchronize do
          @network_entries << entry
          trim!(@network_entries, @network_cap)
        end
      end

      def trim!(buffer, cap)
        return if cap <= 0
        return if buffer.length <= cap

        buffer.shift(buffer.length - cap)
      end

      def safe_message_text(message)
        if message.respond_to?(:text)
          message.text.to_s.byteslice(0, 2000)
        else
          message.to_s.byteslice(0, 2000)
        end
      rescue StandardError
        ""
      end

      def safe_url(obj)
        return obj.url if obj.respond_to?(:url)
        ""
      rescue StandardError
        ""
      end

      def safe_method(request)
        return request.method if request.respond_to?(:method)
        ""
      rescue StandardError
        ""
      end

      # Chrome's DevTools "performance" log entries were JSON strings like
      #   { "message" => '{"method":"Network.requestWillBeSent","params":{...}}' }
      # TaskCaptureSupport already parses that shape. We reconstruct it so
      # summarize_performance_logs / filter_performance_logs work unchanged.
      def wrap_as_chrome_perf_entry(event)
        params = case event[:kind]
                 when "Network.requestWillBeSent"
                   { "requestId" => event[:request_id], "request" => event[:request] }
                 when "Network.responseReceived"
                   { "requestId" => event[:request_id], "response" => event[:response] }
                 when "Network.loadingFailed"
                   { "requestId" => event[:request_id], "errorText" => event[:failure] }
                 else
                   {}
                 end

        inner = { "method" => event[:kind], "params" => params }
        { "timestamp" => event[:timestamp], "message" => { "message" => inner }.to_json }
      end
    end
  end
end
