require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe BinaryCommandResolver do
  let(:harness_class) do
    Class.new do
      include BinaryCommandResolver

      def resolve(command)
        send(:resolve_command_path, command)
      end

      def available?(command)
        send(:command_available?, command)
      end
    end
  end

  let(:harness) { harness_class.new }

  it "expands $HOME-prefixed command paths and detects executables" do
    Dir.mktmpdir("binary_resolver") do |tmp_home|
      bin_dir = File.join(tmp_home, "bin")
      FileUtils.mkdir_p(bin_dir)
      tool_path = File.join(bin_dir, "ffmpeg")
      File.write(tool_path, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod("u+x", tool_path)

      original_home = ENV["HOME"]
      ENV["HOME"] = tmp_home
      begin
        expect(harness.resolve("$HOME/bin/ffmpeg")).to eq(tool_path)
        expect(harness.available?("$HOME/bin/ffmpeg")).to eq(true)
        expect(harness.available?("$HOME/bin/missing")).to eq(false)
      ensure
        ENV["HOME"] = original_home
      end
    end
  end

  it "leaves bare command names unchanged" do
    expect(harness.resolve("ffmpeg")).to eq("ffmpeg")
  end
end
