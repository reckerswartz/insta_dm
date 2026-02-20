source = File.read("app/services/instagram/client.rb")
lines = source.lines

# We extract lines 1654 to 1839 inclusive (0-indexed: 1653 to 1838)
extracted_lines = lines.slice!(1653..1838)

content = extracted_lines.map { |l| l == "\n" ? l : "  " + l }.join

new_module = <<~RUBY
module Instagram
  class Client
    module BrowserAutomation
#{content}
    end
  end
end
RUBY

FileUtils.mkdir_p("app/services/instagram/client") unless Dir.exist?("app/services/instagram/client")
File.write("app/services/instagram/client/browser_automation.rb", new_module)

idx = lines.index { |l| l =~ /^  class Client/ }
lines.insert(idx + 1, "    include BrowserAutomation\n")

File.write("app/services/instagram/client.rb", lines.join)
