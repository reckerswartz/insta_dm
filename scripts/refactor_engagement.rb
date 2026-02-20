source = File.read("app/services/instagram/client.rb")
lines = source.lines

sync_home_story = lines.slice!(201..1106)
auto_engage = lines.slice!(121..199)
capture_home_feed = lines.slice!(59..119)

story_scraper = <<~RUBY
module Instagram
  class Client
    module StoryScraperService
#{sync_home_story.map { |l| l == "\n" ? l : "  " + l }.join}
    end
  end
end
RUBY

feed_engagement = <<~RUBY
module Instagram
  class Client
    module FeedEngagementService
#{capture_home_feed.map { |l| l == "\n" ? l : "  " + l }.join}
#{auto_engage.map { |l| l == "\n" ? l : "  " + l }.join}
    end
  end
end
RUBY

File.write("app/services/instagram/client/story_scraper_service.rb", story_scraper)
File.write("app/services/instagram/client/feed_engagement_service.rb", feed_engagement)

idx = lines.index { |l| l =~ /^  class Client/ }
lines.insert(idx + 1, "    include StoryScraperService\n")
lines.insert(idx + 1, "    include FeedEngagementService\n")

File.write("app/services/instagram/client.rb", lines.join)
