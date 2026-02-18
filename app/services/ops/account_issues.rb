module Ops
  class AccountIssues
    def self.for(account)
      issues = []
      cookie_auth_ok = account.cookie_authenticated?
      session_cookie_present = account.sessionid_cookie_present?

      if account.cookies.blank?
        issues << { level: :bad, message: "No cookies stored. Import cookies or run Manual Browser Login." }
      end

      if account.login_state.to_s != "authenticated" && !session_cookie_present
        issues << { level: :bad, message: "Login state is '#{account.login_state}'. Sync and messaging will likely fail." }
      end

      if account.user_agent.to_s.strip.blank? && !cookie_auth_ok
        issues << { level: :warn, message: "No user-agent saved. Manual login usually captures one; headless sessions can be less stable without it." }
      end

      snap = account.auth_snapshot
      captured_at = snap["captured_at"].to_s
      if captured_at.present?
        begin
          t = Time.iso8601(captured_at)
          issues << { level: :warn, message: "Session bundle captured at #{t.strftime('%Y-%m-%d %H:%M:%S')} UTC." } if t < 30.days.ago && !cookie_auth_ok
        rescue StandardError
          issues << { level: :warn, message: "Auth snapshot captured_at is not parseable." } unless cookie_auth_ok
        end
      else
        issues << { level: :warn, message: "No auth snapshot captured yet." } unless cookie_auth_ok
      end

      if snap["ig_app_id"].to_s.strip.blank? && !cookie_auth_ok
        issues << { level: :warn, message: "No ig_app_id in auth snapshot. API fetches may rely on fallback headers." }
      end

      if !session_cookie_present
        issues << { level: :bad, message: "No sessionid cookie detected. Re-authenticate this account." }
      end

      issues
    end
  end
end
