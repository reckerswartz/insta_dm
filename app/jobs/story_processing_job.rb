class StoryProcessingJob < ApplicationJob
  queue_as :frame_generation

  def perform(instagram_story_id:, force: false)
    story = InstagramStory.find(instagram_story_id)
    StoryProcessingService.new(story: story, force: force).process!
  end
end
