module Instagram
  module Browser
    # Spawns `@playwright/mcp` as a standalone Node sidecar pointing at
    # the same per-account persistent profile dir that production
    # Instagram::Browser::AccountContext uses. The MCP server lets
    # external clients (Claude, Devin, the Playwright MCP Inspector,
    # etc.) drive Chromium through a structured tool protocol.
    #
    # This is an OPERATOR tool. It is *not* called from Sidekiq jobs or
    # the Instagram::Client facade; it has no path into the Rails
    # request/job lifecycle. Use it for:
    #   * Ad-hoc debug sessions ("why is this profile stuck?")
    #   * AI-assistant-driven flows that want browser control
    #   * Running the MCP Inspector against a live session
    #
    # The sidecar shares the same user_data_dir as production, so
    # launching it takes over that profile -- Chromium's on-disk lock
    # will reject a second concurrent opener. Stop any Sidekiq workers
    # (or at least any job that might touch that account) before
    # starting an MCP session.
    #
    # Lifecycle:
    #   bridge = Instagram::Browser::McpBridge.new(account: account)
    #   info = bridge.spawn!(transport: :sse)
    #   # info[:sse_url] -> "http://127.0.0.1:8931/sse"
    #   # info[:pid]     -> PID of the Node process
    #   # ... operator points their MCP client at that URL ...
    #   bridge.stop!(pid: info[:pid])
    class McpBridge
      class NotInstalledError < StandardError; end

      DEFAULT_SSE_PORT = 8931
      DEFAULT_HOST = "127.0.0.1".freeze

      attr_reader :account

      def initialize(account:, port: DEFAULT_SSE_PORT, host: DEFAULT_HOST, headless: false, extra_args: [])
        raise ArgumentError, "account is required" unless account

        @account = account
        @port = port
        @host = host
        @headless = headless
        @extra_args = Array(extra_args)
      end

      # Path to the MCP CLI shim installed by `yarn add @playwright/mcp`.
      # Overridable via PLAYWRIGHT_MCP_CLI_PATH for containerised / shared
      # node_modules layouts.
      def self.cli_path
        return ENV["PLAYWRIGHT_MCP_CLI_PATH"] if ENV["PLAYWRIGHT_MCP_CLI_PATH"].to_s.present?

        bin = Rails.root.join("node_modules", ".bin", "playwright-mcp").to_s
        return bin if File.executable?(bin)

        raise NotInstalledError, "playwright-mcp CLI not found at #{bin}. Run `yarn add --dev @playwright/mcp`."
      end

      def user_data_dir
        AccountContext.sessions_root.join(@account.id.to_s)
      end

      # Builds the command-line args the sidecar will be launched with.
      # `transport`:
      #   :sse    -> SSE transport on host/port (default; what external
      #              MCP clients usually connect to).
      #   :stdio  -> pipe over the spawned process's stdio. Use this when
      #              an MCP client launches the server itself and doesn't
      #              want a network hop. Returns argv only; caller wires
      #              the pipes.
      def command(transport: :sse)
        args = [self.class.cli_path, "--user-data-dir", user_data_dir.to_s]
        args << "--headless" if @headless
        case transport
        when :stdio
          # nothing else; MCP defaults to stdio when --port is absent
        when :sse
          args.concat(["--port", @port.to_s, "--host", @host])
        else
          raise ArgumentError, "unsupported transport: #{transport.inspect}"
        end
        args.concat(@extra_args)
        args
      end

      # Modern MCP streamable-HTTP endpoint. New clients (Claude Desktop,
      # most recent Cursor / Cline builds) expect this path.
      def mcp_url
        "http://#{@host}:#{@port}/mcp"
      end

      # Legacy SSE endpoint. Older MCP client builds still use this; the
      # server exposes both on the same port when launched with --port.
      def sse_url
        "http://#{@host}:#{@port}/sse"
      end

      # Spawns the MCP server as a detached background process. Logs go
      # to `log/playwright_mcp_<account_id>.log` by default. Returns a
      # hash with :pid, :log_path, :mcp_url, :sse_url, :transport,
      # :user_data_dir. Callers are responsible for persisting the PID
      # if they want to stop! later (stop_by_pid keeps the class
      # stateless).
      def spawn!(transport: :sse, log_path: nil, process_runner: Process)
        FileUtils.mkdir_p(user_data_dir)
        log = (log_path || default_log_path).to_s
        FileUtils.mkdir_p(File.dirname(log))

        argv = command(transport: transport)
        pid = process_runner.spawn(*argv, [:out, :err] => [log, "a"])
        process_runner.detach(pid) if process_runner.respond_to?(:detach)

        {
          pid: pid,
          log_path: log,
          mcp_url: transport == :stdio ? nil : mcp_url,
          sse_url: transport == :stdio ? nil : sse_url,
          transport: transport,
          user_data_dir: user_data_dir.to_s,
          account_id: @account.id
        }
      end

      # Terminate a previously-spawned MCP sidecar. Graceful on a
      # missing/already-exited PID. Sends TERM, waits briefly, escalates
      # to KILL.
      def self.stop!(pid:, kill_timeout_seconds: 5, process_runner: Process)
        pid = pid.to_i
        return { stopped: false, reason: "invalid_pid" } if pid <= 0

        begin
          process_runner.kill("TERM", pid)
        rescue Errno::ESRCH
          return { stopped: true, reason: "already_gone", pid: pid }
        end

        deadline = Time.current + kill_timeout_seconds
        while Time.current < deadline
          begin
            process_runner.kill(0, pid)
            sleep 0.1
          rescue Errno::ESRCH
            return { stopped: true, reason: "terminated", pid: pid }
          end
        end

        begin
          process_runner.kill("KILL", pid)
        rescue Errno::ESRCH
        end
        { stopped: true, reason: "killed", pid: pid }
      end

      def self.alive?(pid:, process_runner: Process)
        return false if pid.to_i <= 0

        process_runner.kill(0, pid.to_i)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      private

      def default_log_path
        Rails.root.join("log", "playwright_mcp_#{@account.id}.log")
      end
    end
  end
end
