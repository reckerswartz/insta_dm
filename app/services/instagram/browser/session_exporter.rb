module Instagram
  module Browser
    # Synchronizes a Playwright persistent context with the encrypted
    # InstagramAccount session columns (cookies_json, local_storage_json,
    # user_agent, auth_snapshot_json).
    #
    # The on-disk user data dir is the production source of truth: Playwright
    # loads cookies, IndexedDB, service workers, etc. from there on every
    # launch. The DB columns exist as:
    #
    #   * a portable backup so an account can be moved to a new host, and
    #   * an import path for operators who received cookies from an
    #     external tool (or the legacy Selenium flow).
    #
    # Translation between Playwright's `storage_state` shape and the legacy
    # column shape is lossy-preserving: cookie attribute names are
    # normalized (`httpOnly` <-> `http_only`) and localStorage entries are
    # tagged with their origin so they can be reconstructed per-site.
    class SessionExporter
      attr_reader :account

      def initialize(account:)
        @account = account
      end

      # Reads storage_state from a live Playwright browser_context and
      # writes cookies + localStorage + user_agent into the encrypted DB
      # columns. Returns the storage_state hash for inspection.
      def export!(context)
        raw = context.storage_state
        state = normalize_state(raw)

        account.cookies = state.fetch(:cookies, [])
        account.local_storage = flatten_origins(state.fetch(:origins, []), kind: :localStorage)
        account.user_agent = state.dig(:user_agent).presence || account.user_agent
        account.auth_snapshot = (account.auth_snapshot || {}).merge(
          "exported_at" => Time.current.iso8601,
          "origins" => state.fetch(:origins, []).map { |o| o[:origin] }.compact
        )
        account.save!
        state
      end

      # Converts the DB columns back into a Playwright-compatible
      # storage_state hash. Useful for `context.storage_state=` at launch,
      # or for `browser.new_context(storage_state: ...)` flows.
      def storage_state
        {
          cookies: Array(account.cookies).map { |c| normalize_cookie_for_playwright(c) }.compact,
          origins: origins_from_local_storage(account.local_storage)
        }
      end

      # Writes the DB-backed state back out as JSON to a fresh user_data_dir
      # file that Chromium will pick up on launch. Not required for normal
      # operation (the persistent context already has everything on disk)
      # but lets ops bootstrap a new host: paste the DB row, call import!,
      # start the AccountContext, skip manual_login!.
      def import!(path:)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(storage_state))
        path
      end

      private

      def normalize_state(raw)
        return {} if raw.nil?

        hash = raw.respond_to?(:to_h) ? raw.to_h : raw
        hash.deep_symbolize_keys
      end

      def flatten_origins(origins, kind:)
        Array(origins).flat_map do |origin|
          entries = Array(origin[kind])
          entries.map { |e| { origin: origin[:origin], name: e[:name], value: e[:value] }.compact }
        end
      end

      def origins_from_local_storage(entries)
        grouped = Array(entries).group_by { |e| e["origin"] || e[:origin] }
        grouped.map do |origin, items|
          next if origin.blank?

          {
            origin: origin,
            localStorage: items.map { |i| { name: i["name"] || i[:name], value: i["value"] || i[:value] } }
          }
        end.compact
      end

      # Playwright wants camelCase keys (`httpOnly`, `sameSite`) and a
      # numeric `expires` (-1 for session cookies). Translate whatever
      # shape the legacy Selenium bundle used.
      def normalize_cookie_for_playwright(cookie)
        return nil unless cookie.is_a?(Hash)

        name   = cookie["name"] || cookie[:name]
        value  = cookie["value"] || cookie[:value]
        domain = cookie["domain"] || cookie[:domain]
        return nil if name.blank? || value.nil?

        http_only = cookie.fetch("httpOnly") { cookie["http_only"] || cookie[:httpOnly] || cookie[:http_only] || false }
        same_site = cookie.fetch("sameSite") { cookie["same_site"] || cookie[:sameSite] || cookie[:same_site] || "Lax" }
        secure    = cookie.fetch("secure") { cookie[:secure] || false }
        path      = cookie.fetch("path") { cookie[:path] || "/" }
        expires   = normalize_expires(cookie["expires"] || cookie["expiry"] || cookie[:expires] || cookie[:expiry])

        {
          name: name,
          value: value,
          domain: domain,
          path: path,
          expires: expires,
          httpOnly: !!http_only,
          secure: !!secure,
          sameSite: normalize_same_site(same_site)
        }.compact
      end

      def normalize_expires(raw)
        return -1 if raw.nil?
        return raw.to_i if raw.is_a?(Numeric)
        Time.parse(raw.to_s).to_i
      rescue StandardError
        -1
      end

      def normalize_same_site(raw)
        val = raw.to_s.capitalize
        %w[Strict Lax None].include?(val) ? val : "Lax"
      end
    end
  end
end
