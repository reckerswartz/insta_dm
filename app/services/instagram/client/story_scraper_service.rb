module Instagram
  class Client
    module StoryScraperService
      # Facade composition for story scraping workflows.
      # Keep this module thin; implementation lives in StoryScraper::* components.
      include StoryScraper::HomeCarouselSync
      include StoryScraper::CarouselOpening
      include StoryScraper::CarouselNavigation
    end
  end
end
