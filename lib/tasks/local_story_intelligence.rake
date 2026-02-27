require "json"

namespace :ai do
  desc "Backfill local story intelligence metadata. Usage: rake ai:backfill_local_story_intelligence[account_id,limit,enqueue_comments]"
  task :backfill_local_story_intelligence, [ :account_id, :limit, :enqueue_comments ] => :environment do |_task, args|
    service = Ops::LocalStoryIntelligenceBackfill.new(
      account_id: args[:account_id],
      limit: args[:limit],
      enqueue_comments: args[:enqueue_comments]
    )
    result = service.backfill!
    puts JSON.pretty_generate(result)
  end

  desc "Requeue story comment generation for failed/stale/generic records. Usage: rake ai:requeue_story_llm_comments[account_id,limit]"
  task :requeue_story_llm_comments, [ :account_id, :limit ] => :environment do |_task, args|
    service = Ops::LocalStoryIntelligenceBackfill.new(
      account_id: args[:account_id],
      limit: args[:limit],
      enqueue_comments: false
    )
    result = service.requeue_generation!
    puts JSON.pretty_generate(result)
  end

  desc "Requeue pending video story comments (not_requested) so each item gets explicit terminal status. Usage: rake ai:requeue_pending_video_story_comments[account_id,limit]"
  task :requeue_pending_video_story_comments, [ :account_id, :limit ] => :environment do |_task, args|
    service = Ops::LocalStoryIntelligenceBackfill.new(
      account_id: args[:account_id],
      limit: args[:limit],
      enqueue_comments: false
    )
    result = service.requeue_pending_video_generation!
    puts JSON.pretty_generate(result)
  end

  desc "Audit story comment specificity and optional regenerate. Usage: rake ai:audit_story_comment_specificity[account_id,story_ids_csv,limit,regenerate,wait]"
  task :audit_story_comment_specificity, [ :account_id, :story_ids, :limit, :regenerate, :wait ] => :environment do |_task, args|
    service = Ops::StoryCommentSpecificityAudit.new(
      account_id: args[:account_id],
      story_ids: args[:story_ids],
      limit: args[:limit],
      regenerate: args[:regenerate],
      wait: args[:wait]
    )
    result = service.call
    puts JSON.pretty_generate(result)
  end
end
