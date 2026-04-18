# frozen_string_literal: true

# Operator-facing rake tasks to manage an ad-hoc @playwright/mcp sidecar
# pointed at an InstagramAccount's persistent browser profile.
#
# Not wired into jobs or the facade. The sidecar shares the account's
# user_data_dir with production, so pause any Sidekiq worker that might
# touch that profile before starting an MCP session.
#
# State file
#   tmp/playwright_mcp/<account_id>.json
# holds the PID + sse_url + log_path so subsequent `rake` calls can find
# the running sidecar without the operator remembering the PID.
namespace :playwright do
  namespace :mcp do
    desc "Start the Playwright MCP sidecar for an account. ACCOUNT=<id> [PORT=8931] [HOST=127.0.0.1] [HEADLESS=true|false] [TRANSPORT=sse|stdio]"
    task start: :environment do
      account = resolve_account!
      port = Integer(ENV.fetch("PORT", Instagram::Browser::McpBridge::DEFAULT_SSE_PORT))
      host = ENV.fetch("HOST", Instagram::Browser::McpBridge::DEFAULT_HOST)
      headless = ActiveModel::Type::Boolean.new.cast(ENV.fetch("HEADLESS", "false"))
      transport = ENV.fetch("TRANSPORT", "sse").to_sym

      existing = read_state(account_id: account.id)
      if existing && Instagram::Browser::McpBridge.alive?(pid: existing["pid"])
        puts "Already running: pid=#{existing['pid']} sse_url=#{existing['sse_url']}"
        puts "Stop first with: rake playwright:mcp:stop ACCOUNT=#{account.id}"
        exit(0)
      end

      bridge = Instagram::Browser::McpBridge.new(
        account: account, port: port, host: host, headless: headless
      )
      info = bridge.spawn!(transport: transport)
      write_state(account_id: account.id, info: info)

      puts "Started Playwright MCP sidecar for account #{account.id} (#{account.username})."
      puts "  pid:        #{info[:pid]}"
      puts "  transport:  #{info[:transport]}"
      puts "  mcp_url:    #{info[:mcp_url]} (preferred; streamable HTTP)" if info[:mcp_url]
      puts "  sse_url:    #{info[:sse_url]} (legacy SSE transport)" if info[:sse_url]
      puts "  user_data:  #{info[:user_data_dir]}"
      puts "  log:        #{info[:log_path]}"
      puts
      puts "Configure your MCP client with:"
      if info[:transport] == :sse
        puts "  {\"mcpServers\":{\"playwright\":{\"url\":\"#{info[:mcp_url]}\"}}}"
      else
        puts "  command: #{Instagram::Browser::McpBridge.cli_path}"
        puts "  args:    #{Instagram::Browser::McpBridge.new(account: account, headless: headless).command(transport: :stdio)[1..].inspect}"
      end
    end

    desc "Stop the Playwright MCP sidecar. ACCOUNT=<id>"
    task stop: :environment do
      account = resolve_account!
      state = read_state(account_id: account.id)

      unless state
        puts "No tracked MCP sidecar for account #{account.id}."
        exit(0)
      end

      result = Instagram::Browser::McpBridge.stop!(pid: state["pid"])
      puts "Stop result: #{result.inspect}"
      clear_state(account_id: account.id)
    end

    desc "Show status + connection info for the MCP sidecar. ACCOUNT=<id>"
    task status: :environment do
      account = resolve_account!
      state = read_state(account_id: account.id)
      if state.nil?
        puts "No tracked MCP sidecar for account #{account.id}."
        exit(0)
      end

      alive = Instagram::Browser::McpBridge.alive?(pid: state["pid"])
      puts "account_id:  #{account.id} (#{account.username})"
      puts "pid:         #{state['pid']} (#{alive ? 'alive' : 'DEAD'})"
      puts "transport:   #{state['transport']}"
      puts "mcp_url:     #{state['mcp_url']}" if state["mcp_url"]
      puts "sse_url:     #{state['sse_url']}" if state["sse_url"]
      puts "log_path:    #{state['log_path']}"
      puts "user_data:   #{state['user_data_dir']}"
      unless alive
        puts
        puts "Process is gone; run `rake playwright:mcp:stop ACCOUNT=#{account.id}` to clean up the state file,"
        puts "then `rake playwright:mcp:start ACCOUNT=#{account.id}` to relaunch."
      end
    end

    # ----- helpers below -----

    def resolve_account!
      id = ENV.fetch("ACCOUNT") do
        abort "Set ACCOUNT=<instagram_account_id> (found in /admin or InstagramAccount.pluck(:id, :username))."
      end
      InstagramAccount.find(id)
    rescue ActiveRecord::RecordNotFound
      abort "InstagramAccount not found for ACCOUNT=#{id}"
    end

    def state_dir
      Rails.root.join("tmp", "playwright_mcp").tap { |d| FileUtils.mkdir_p(d) }
    end

    def state_path(account_id:)
      state_dir.join("#{account_id}.json")
    end

    def read_state(account_id:)
      path = state_path(account_id: account_id)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write_state(account_id:, info:)
      File.write(state_path(account_id: account_id), JSON.pretty_generate(info.transform_keys(&:to_s)))
    end

    def clear_state(account_id:)
      path = state_path(account_id: account_id)
      File.delete(path) if File.exist?(path)
    end
  end
end
