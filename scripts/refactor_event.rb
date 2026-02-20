require 'fileutils'
source = File.read("app/models/instagram_profile_event.rb")
lines = source.lines

operations = [
  { mod: "LocalStoryIntelligence", range: [1072, 1137] },
  { mod: "LocalStoryIntelligence", range: [1043, 1070] },
  { mod: "LocalStoryIntelligence", range: [1028, 1041] },
  { mod: "LocalStoryIntelligence", range: [1011, 1026] },
  { mod: "LocalStoryIntelligence", range: [985, 1009] },
  { mod: "LocalStoryIntelligence", range: [976, 983] },
  { mod: "LocalStoryIntelligence", range: [968, 974] },
  { mod: "LocalStoryIntelligence", range: [940, 966] },
  { mod: "LocalStoryIntelligence", range: [868, 938] },
  { mod: "LocalStoryIntelligence", range: [815, 866] },
  { mod: "LocalStoryIntelligence", range: [622, 813] },
  { mod: "CommentGenerationCoordinator", range: [532, 620] },
  { mod: "CommentGenerationCoordinator", range: [512, 530] },
  { mod: "Broadcastable", range: [498, 510] },
  { mod: "Broadcastable", range: [489, 496] },
  { mod: "Broadcastable", range: [471, 478] },
  { mod: "Broadcastable", range: [456, 467] },
  { mod: "Broadcastable", range: [437, 454] },
  { mod: "Broadcastable", range: [419, 435] },
  { mod: "Broadcastable", range: [402, 417] },
  { mod: "Broadcastable", range: [384, 400] },
  { mod: "Broadcastable", range: [363, 382] },
  { mod: "Broadcastable", range: [344, 361] },
  { mod: "CommentGenerationCoordinator", range: [258, 260] },
  { mod: "CommentGenerationCoordinator", range: [122, 256] },
  { mod: "CommentGenerationCoordinator", range: [89, 120] },
  { mod: "CommentGenerationCoordinator", range: [71, 87] },
  { mod: "CommentGenerationCoordinator", range: [60, 69] },
  { mod: "CommentGenerationCoordinator", range: [50, 58] },
  { mod: "CommentGenerationCoordinator", range: [46, 48] },
  { mod: "CommentGenerationCoordinator", range: [42, 44] },
  { mod: "LocalStoryIntelligence", range: [4, 12] }
]

modules = { 
  "LocalStoryIntelligence" => [], 
  "Broadcastable" => [], 
  "CommentGenerationCoordinator" => [] 
}

operations.each do |op|
  start_idx = op[:range][0] - 1
  end_idx = op[:range][1] - 1
  extracted = lines.slice!(start_idx..end_idx)
  modules[op[:mod]].unshift(*extracted)
end

def wrap(m, c)
  <<~RUBY
require 'active_support/concern'

module InstagramProfileEvent::#{m}
  extend ActiveSupport::Concern

  included do
#{c.map { |l| l == "\n" ? l : "    " + l.sub(/^  /, '') }.join}
  end
end
  RUBY
end

FileUtils.mkdir_p("app/models/instagram_profile_event")
modules.each do |mod, code|
  File.write("app/models/instagram_profile_event/#{mod.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase}.rb", wrap(mod, code))
end

idx = lines.index { |l| l =~ /^class InstagramProfileEvent/ }
lines.insert(idx + 1, "  include InstagramProfileEvent::CommentGenerationCoordinator\n")
lines.insert(idx + 1, "  include InstagramProfileEvent::Broadcastable\n")
lines.insert(idx + 1, "  include InstagramProfileEvent::LocalStoryIntelligence\n")

File.write("app/models/instagram_profile_event.rb", lines.join)
