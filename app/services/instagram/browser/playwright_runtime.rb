require "playwright"

module Instagram
  module Browser
    # Process-wide Playwright driver. One Node subprocess per Ruby process,
    # shared across all InstagramAccount contexts. Callers should go through
    # Instagram::Browser::AccountContext; this class exists so we don't spawn
    # a new Node per job.
    #
    # Thread-safe: Playwright#create is guarded by a mutex so concurrent
    # Sidekiq threads boot at most one driver.
    #
    # Multi-process note: every Sidekiq worker process has its own runtime
    # instance. That's fine; Playwright is per-process and chromium user
    # data dirs are the single-writer guard across the Playwright instances.
    class PlaywrightRuntime
      class NotInstalledError < StandardError; end

      PLAYWRIGHT_CLI_ENV = "PLAYWRIGHT_CLI_EXECUTABLE_PATH".freeze

      @mutex = Mutex.new
      @execution = nil

      class << self
        # Returns the shared Playwright API root (a Playwright::Playwright)
        # with `.chromium`, `.firefox`, `.webkit`, `.devices`. Boots the
        # underlying Node subprocess on first access.
        def driver
          @mutex.synchronize do
            @execution ||= build_execution!
          end
          @execution.playwright
        end

        # Yields the driver and guarantees teardown for short-lived callers
        # (rake tasks, smoke tests). The long-lived process path should use
        # `driver` and let at_exit handle shutdown.
        def with_driver
          yield driver
        end

        # Idempotent shutdown. Safe to call in at_exit / signal handlers.
        def shutdown!
          @mutex.synchronize do
            next unless @execution

            begin
              @execution.stop
            rescue StandardError
              # Node already gone; ignore.
            end
            @execution = nil
          end
        end

        def running?
          !@execution.nil?
        end

        # Path to the Playwright CLI shim installed by the npm package.
        # Overridable via PLAYWRIGHT_CLI_EXECUTABLE_PATH for non-standard
        # layouts (e.g. shared node_modules in container images).
        def cli_executable_path
          return ENV[PLAYWRIGHT_CLI_ENV] if ENV[PLAYWRIGHT_CLI_ENV].to_s.present?

          bin = Rails.root.join("node_modules", ".bin", "playwright").to_s
          return bin if File.executable?(bin)

          raise NotInstalledError, "Playwright CLI not found at #{bin}. Run `yarn add --dev playwright@#{Playwright::VERSION}` and `npx playwright install chromium`."
        end

        private

        def build_execution!
          Playwright.create(playwright_cli_executable_path: cli_executable_path)
        end
      end

      # Best-effort shutdown when the Ruby process exits.
      at_exit { shutdown! if running? }
    end
  end
end
