class StoryProcessingJob < ApplicationJob
  queue_as :frame_generation

  def perform(instagram_story_id:, force: false)
    story = InstagramStory.find_by(id: instagram_story_id)
    unless story
      Ops::StructuredLogger.info(
        event: "story_processing.skipped_missing_story",
        payload: { instagram_story_id: instagram_story_id, force: force }
      )
      return
    end

    StoryProcessingService.new(story: story, force: force).process!
  end
end
