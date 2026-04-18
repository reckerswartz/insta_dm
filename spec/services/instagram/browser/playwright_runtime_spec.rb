require "rails_helper"

RSpec.describe Instagram::Browser::PlaywrightRuntime do
  describe ".cli_executable_path" do
    it "honors the PLAYWRIGHT_CLI_EXECUTABLE_PATH env var" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PLAYWRIGHT_CLI_EXECUTABLE_PATH").and_return("/fake/path")
      expect(described_class.cli_executable_path).to eq("/fake/path")
    end

    it "points to node_modules/.bin/playwright when the env var is unset and the shim exists" do
      fake_root = Pathname.new(Dir.mktmpdir)
      FileUtils.mkdir_p(fake_root.join("node_modules/.bin"))
      shim = fake_root.join("node_modules/.bin/playwright")
      File.write(shim, "#!/bin/sh\n"); File.chmod(0o755, shim)

      allow(Rails).to receive(:root).and_return(fake_root)
      allow(ENV).to receive(:[]).with("PLAYWRIGHT_CLI_EXECUTABLE_PATH").and_return(nil)

      expect(described_class.cli_executable_path).to eq(shim.to_s)
    ensure
      FileUtils.rm_rf(fake_root) if fake_root
    end

    it "raises NotInstalledError when neither override nor shim exists" do
      fake_root = Pathname.new(Dir.mktmpdir)
      allow(Rails).to receive(:root).and_return(fake_root)
      allow(ENV).to receive(:[]).with("PLAYWRIGHT_CLI_EXECUTABLE_PATH").and_return(nil)

      expect { described_class.cli_executable_path }
        .to raise_error(described_class::NotInstalledError, /Playwright CLI not found/)
    ensure
      FileUtils.rm_rf(fake_root) if fake_root
    end
  end

  describe ".driver / .shutdown!" do
    it "lazily boots a single Playwright execution and reuses it across calls" do
      execution = instance_double("Playwright::Execution", playwright: :playwright_root, stop: nil)
      expect(Playwright).to receive(:create).once.and_return(execution)

      # Reset module-level state for the test.
      described_class.instance_variable_set(:@execution, nil)
      expect(described_class.running?).to be(false)

      expect(described_class.driver).to eq(:playwright_root)
      expect(described_class.driver).to eq(:playwright_root)
      expect(described_class.running?).to be(true)

      described_class.shutdown!
      expect(described_class.running?).to be(false)
    end

    it "#with_driver yields the playwright root" do
      execution = instance_double("Playwright::Execution", playwright: :pw, stop: nil)
      expect(Playwright).to receive(:create).once.and_return(execution)
      described_class.instance_variable_set(:@execution, nil)

      expect { |b| described_class.with_driver(&b) }.to yield_with_args(:pw)

      described_class.shutdown!
    end
  end
end
