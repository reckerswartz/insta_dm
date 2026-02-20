source = File.read("app/services/instagram/client.rb")
lines = source.lines

operations = [
  { mod: "StoryScraperService", range: [5772, 5822] },
  { mod: "StoryScraperService", range: [5635, 5699] },
  { mod: "StoryScraperService", range: [5292, 5526] },
  { mod: "BrowserAutomation", range: [1654, 1839] },
  { mod: "StoryScraperService", range: [202, 1107] },
  { mod: "FeedEngagementService", range: [122, 200] },
  { mod: "FeedEngagementService", range: [60, 120] }
]

modules = { "StoryScraperService" => [], "BrowserAutomation" => [], "FeedEngagementService" => [] }

operations.each do |op|
  start_idx = op[:range][0] - 1
  end_idx = op[:range][1] - 1
  extracted = lines.slice!(start_idx..end_idx)
  modules[op[:mod]].unshift(*extracted)
end

def wrap(m, c)
  <<~RUBY
module Instagram
  class Client
    module #{m}
#{c.map { |l| l == "\n" ? l : "  " + l }.join}
    end
  end
end
  RUBY
end

modules.each do |mod, code|
  File.write("app/services/instagram/client/#{mod.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.rb", wrap(mod, code))
end

idx = lines.index { |l| l =~ /^  class Client/ }
lines.insert(idx + 1, "    include BrowserAutomation\n")
lines.insert(idx + 1, "    include FeedEngagementService\n")
lines.insert(idx + 1, "    include StoryScraperService\n")

File.write("app/services/instagram/client.rb", lines.join)
