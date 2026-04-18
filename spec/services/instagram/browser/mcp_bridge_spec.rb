require "rails_helper"

RSpec.describe Instagram::Browser::McpBridge do
  let(:tmp_root) { Pathname.new(Dir.mktmpdir("mcp_spec_")) }
  let(:account) { InstagramAccount.create!(username: "mcp_#{SecureRandom.hex(4)}") }

  before do
    ENV["PLAYWRIGHT_BROWSER_SESSIONS_ROOT"] = tmp_root.to_s
    # Force the shim path lookup to a deterministic location.
    ENV["PLAYWRIGHT_MCP_CLI_PATH"] = "/fake/bin/playwright-mcp"
  end

  after do
    ENV.delete("PLAYWRIGHT_BROWSER_SESSIONS_ROOT")
    ENV.delete("PLAYWRIGHT_MCP_CLI_PATH")
    FileUtils.rm_rf(tmp_root)
  end

  describe ".cli_path" do
    it "honors PLAYWRIGHT_MCP_CLI_PATH" do
      expect(described_class.cli_path).to eq("/fake/bin/playwright-mcp")
    end

    it "raises NotInstalledError when neither the env var nor node_modules/.bin/playwright-mcp is present" do
      ENV.delete("PLAYWRIGHT_MCP_CLI_PATH")
      fake_root = Pathname.new(Dir.mktmpdir("mcp_cli_probe_"))
      allow(Rails).to receive(:root).and_return(fake_root)

      expect { described_class.cli_path }.to raise_error(described_class::NotInstalledError, /playwright-mcp/)
    ensure
      FileUtils.rm_rf(fake_root) if fake_root
    end
  end

  describe "#user_data_dir" do
    it "points at PLAYWRIGHT_BROWSER_SESSIONS_ROOT/<account_id>/" do
      bridge = described_class.new(account: account)
      expect(bridge.user_data_dir.to_s).to eq(tmp_root.join(account.id.to_s).to_s)
    end
  end

  describe "#command" do
    it "builds an SSE argv with --user-data-dir, --port, --host" do
      bridge = described_class.new(account: account, port: 9000, host: "0.0.0.0")
      argv = bridge.command(transport: :sse)
      expect(argv.first).to eq("/fake/bin/playwright-mcp")
      expect(argv).to include("--user-data-dir", tmp_root.join(account.id.to_s).to_s)
      expect(argv).to include("--port", "9000")
      expect(argv).to include("--host", "0.0.0.0")
      expect(argv).not_to include("--headless")
    end

    it "adds --headless when headless: true" do
      bridge = described_class.new(account: account, headless: true)
      expect(bridge.command(transport: :sse)).to include("--headless")
    end

    it "omits --port/--host for stdio transport" do
      bridge = described_class.new(account: account)
      argv = bridge.command(transport: :stdio)
      expect(argv).to include("--user-data-dir")
      expect(argv).not_to include("--port")
      expect(argv).not_to include("--host")
    end

    it "appends extra_args verbatim (caps, config, allowed-origins, etc.)" do
      bridge = described_class.new(account: account, extra_args: ["--caps", "vision,pdf"])
      argv = bridge.command(transport: :sse)
      expect(argv.last(2)).to eq(["--caps", "vision,pdf"])
    end

    it "raises on an unknown transport" do
      expect { described_class.new(account: account).command(transport: :grpc) }
        .to raise_error(ArgumentError, /unsupported transport/)
    end
  end

  describe "#sse_url / #mcp_url" do
    it "combines host + port into the MCP URL shapes" do
      bridge = described_class.new(account: account, host: "10.0.0.5", port: 8931)
      expect(bridge.sse_url).to eq("http://10.0.0.5:8931/sse")
      expect(bridge.mcp_url).to eq("http://10.0.0.5:8931/mcp")
    end
  end

  describe "#spawn!" do
    it "calls Process.spawn with the computed argv and redirects stdout/stderr to the log file" do
      runner = double("ProcessRunner")
      expect(runner).to receive(:spawn) do |*args, **opts|
        expect(args).to include("/fake/bin/playwright-mcp", "--user-data-dir", "--port", "8931")
        expect(opts[[:out, :err]]).to be_an(Array)
        expect(opts[[:out, :err]].first).to include("playwright_mcp_#{account.id}.log")
        expect(opts[[:out, :err]].last).to eq("a")
        12_345
      end
      expect(runner).to receive(:detach).with(12_345)

      bridge = described_class.new(account: account)
      info = bridge.spawn!(process_runner: runner)

      expect(info[:pid]).to eq(12_345)
      expect(info[:sse_url]).to eq("http://127.0.0.1:8931/sse")
      expect(info[:mcp_url]).to eq("http://127.0.0.1:8931/mcp")
      expect(info[:transport]).to eq(:sse)
      expect(info[:account_id]).to eq(account.id)
    end

    it "ensures the user_data_dir exists before spawning (so MCP doesn't race on the first launch)" do
      runner = double("ProcessRunner", spawn: 1, detach: nil)
      bridge = described_class.new(account: account)
      bridge.spawn!(process_runner: runner)

      expect(File.directory?(tmp_root.join(account.id.to_s))).to be(true)
    end

    it "returns mcp_url/sse_url as nil for stdio transport" do
      runner = double("ProcessRunner", spawn: 1, detach: nil)
      info = described_class.new(account: account).spawn!(transport: :stdio, process_runner: runner)
      expect(info[:sse_url]).to be_nil
      expect(info[:mcp_url]).to be_nil
      expect(info[:transport]).to eq(:stdio)
    end
  end

  describe ".stop!" do
    it "sends TERM then returns :terminated when the process disappears" do
      runner = Class.new do
        def initialize; @calls = 0; end
        attr_reader :calls
        def kill(sig, pid)
          @calls += 1
          case sig
          when "TERM" then true
          when 0 then raise Errno::ESRCH
          else raise Errno::ESRCH
          end
        end
      end.new

      result = described_class.stop!(pid: 42, process_runner: runner)
      expect(result[:stopped]).to be(true)
      expect(result[:reason]).to eq("terminated")
    end

    it "returns :already_gone when TERM raises ESRCH" do
      runner = double("ProcessRunner")
      allow(runner).to receive(:kill).with("TERM", 42).and_raise(Errno::ESRCH)

      expect(described_class.stop!(pid: 42, process_runner: runner)[:reason]).to eq("already_gone")
    end

    it "escalates to KILL after the timeout" do
      runner = double("ProcessRunner")
      allow(runner).to receive(:kill).with("TERM", 42).and_return(true)
      allow(runner).to receive(:kill).with(0, 42).and_return(true)   # process keeps responding to signal 0
      expect(runner).to receive(:kill).with("KILL", 42).and_return(true)

      result = described_class.stop!(pid: 42, kill_timeout_seconds: 0.01, process_runner: runner)
      expect(result[:reason]).to eq("killed")
    end

    it "rejects an invalid pid" do
      expect(described_class.stop!(pid: 0)).to eq({ stopped: false, reason: "invalid_pid" })
    end
  end

  describe ".alive?" do
    it "returns false for a dead pid" do
      runner = double("ProcessRunner")
      allow(runner).to receive(:kill).with(0, 1234).and_raise(Errno::ESRCH)
      expect(described_class.alive?(pid: 1234, process_runner: runner)).to be(false)
    end

    it "returns true when kill(0) succeeds" do
      runner = double("ProcessRunner", kill: true)
      expect(described_class.alive?(pid: 1234, process_runner: runner)).to be(true)
    end
  end
end
