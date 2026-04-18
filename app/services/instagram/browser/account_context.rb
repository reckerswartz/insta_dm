module Instagram
  module Browser
    # Per-InstagramAccount Playwright persistent context manager.
    #
    # Each account gets its own Chromium user data dir under
    # `storage/browser_sessions/<account_id>/`. The first time the context
    # opens, the user logs in manually; cookies / localStorage / IndexedDB /
    # service workers all persist on disk. Subsequent jobs open the same
    # directory and inherit the authenticated session with no DB round-trip.
    #
    # Only one Chromium instance per account may run at a time. A per-account
    # Mutex enforces that inside a single Ruby process. Across processes
    # (multiple Sidekiq workers), Chromium's own profile-lock file rejects
    # concurrent opens of the same user_data_dir — so callers will hit a
    # Playwright error rather than silently corrupt the profile. See
    # docs/operations/browser-sessions.md (added in Phase 6) for details.
    class AccountContext
      DEFAULT_VIEWPORT = { width: 1400, height: 1200 }.freeze
      DEFAULT_USER_AGENT =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
        "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36".freeze

      @account_mutexes = {}
      @registry_mutex = Mutex.new

      class << self
        # Reentrant-safe: the same process/thread can nest #with_context
        # blocks for the same account if needed (rare; mostly useful for
        # testing). Mutex is non-reentrant so we namespace carefully.
        def mutex_for(account_id)
          @registry_mutex.synchronize do
            @account_mutexes[account_id.to_i] ||= Mutex.new
          end
        end

        # Root dir. Overridable for tests via PLAYWRIGHT_BROWSER_SESSIONS_ROOT.
        def sessions_root
          Pathname.new(
            ENV["PLAYWRIGHT_BROWSER_SESSIONS_ROOT"].presence ||
              Rails.root.join("storage", "browser_sessions").to_s
          )
        end
      end

      attr_reader :account, :headless

      def initialize(account:, headless: default_headless?, user_agent: nil, viewport: nil, runtime: Instagram::Browser::PlaywrightRuntime)
        raise ArgumentError, "account is required" unless account

        @account = account
        @headless = headless
        @user_agent = user_agent
        @viewport = viewport || DEFAULT_VIEWPORT
        @runtime = runtime
      end

      def user_data_dir
        self.class.sessions_root.join(@account.id.to_s)
      end

      # Yields a `browser_context` (Playwright::BrowserContext) ready to
      # drive. The context is closed when the block returns; the user data
      # dir on disk is preserved so the next call re-authenticates silently.
      #
      # Callers that want a page should do:
      #   context.with_context { |ctx| page = ctx.new_page; ... }
      def with_context(&block)
        raise ArgumentError, "block required" unless block

        self.class.mutex_for(@account.id).synchronize do
          ensure_user_data_dir!

          @runtime.with_driver do |driver|
            launched = driver.chromium.launch_persistent_context(
              user_data_dir.to_s,
              headless: @headless,
              viewport: @viewport,
              userAgent: effective_user_agent,
              args: launch_args
            )

            begin
              yield launched
            ensure
              safe_close(launched)
            end
          end
        end
      end

      # Convenience: opens a context, yields the first (or a new) page.
      # Instagram::Browser::PageInstrumentation is attached so downstream
      # TaskCaptureSupport / detect_websocket_tls_issue have console +
      # network logs available.
      def with_page(&block)
        with_context do |context|
          page = context.pages.first || context.new_page
          Instagram::Browser::PageInstrumentation.attach!(page)
          yield page, context
        end
      end

      # Removes the on-disk user data dir. Destructive; caller confirms.
      def wipe!
        return unless user_data_dir.exist?

        FileUtils.rm_rf(user_data_dir)
      end

      def exists_on_disk?
        user_data_dir.exist? && Dir.children(user_data_dir.to_s).any?
      end

      private

      def ensure_user_data_dir!
        FileUtils.mkdir_p(user_data_dir)
      end

      def effective_user_agent
        @user_agent.presence || @account.user_agent.presence || DEFAULT_USER_AGENT
      end

      def launch_args
        args = [
          "--window-size=#{@viewport[:width]},#{@viewport[:height]}",
          "--disable-notifications",
          "--disable-dev-shm-usage",
          "--disable-gpu",
          "--no-sandbox"
        ]
        if ActiveModel::Type::Boolean.new.cast(ENV["INSTAGRAM_CHROME_IGNORE_CERT_ERRORS"])
          args << "--ignore-certificate-errors"
          args << "--ignore-ssl-errors=yes"
        end
        args
      end

      def default_headless?
        value = ENV["INSTAGRAM_HEADLESS"]
        return true if value.nil?

        ActiveModel::Type::Boolean.new.cast(value)
      end

      def safe_close(context)
        context.close
      rescue StandardError => e
        Rails.logger&.warn("AccountContext#close error (ignoring): #{e.class}: #{e.message}")
      end
    end
  end
end
