class SyncAllHomeStoriesJob < ApplicationJob
  queue_as :story_downloads

  MAX_CYCLES = 30

  def perform(instagram_account_id:, cycle_story_limit: SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT)
    account = InstagramAccount.find(instagram_account_id)
    batch_limit = cycle_story_limit.to_i.clamp(1, SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT)

    totals = Hash.new(0)
    cycles = 0
    idle_cycles = 0
    stop_reason = "max_cycles_reached"

    MAX_CYCLES.times do
      cycles += 1
      result = Instagram::Client.new(account: account).sync_home_story_carousel!(story_limit: batch_limit, auto_reply_only: false)
      merge_totals!(totals, result)

      moved_work = result[:downloaded].to_i + result[:commented].to_i + result[:analyzed].to_i
      idle_cycles = moved_work.zero? ? idle_cycles + 1 : 0

      if result[:stories_visited].to_i < batch_limit
        stop_reason = "depleted_before_batch_limit"
        break
      end

      if idle_cycles >= 2
        stop_reason = "no_new_work_for_two_cycles"
        break
      end
    end

    message = "Continuous story sync done: cycles=#{cycles}, reason=#{stop_reason}, visited=#{totals[:stories_visited]}, downloaded=#{totals[:downloaded]}, analyzed=#{totals[:analyzed]}, commented=#{totals[:commented]}, reacted=#{totals[:reacted]}, skipped_ads=#{totals[:skipped_ads]}, skipped_unreplyable=#{totals[:skipped_unreplyable]}, skipped_interaction_retry=#{totals[:skipped_interaction_retry]}, skipped_reshared_external_link=#{totals[:skipped_reshared_external_link]}, failed=#{totals[:failed]}."
    kind = totals[:failed].to_i.positive? ? "alert" : "notice"

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: kind, message: message }
    )
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Continuous story sync failed: #{e.message}" }
    ) if account
    raise
  end

  private

  def merge_totals!(totals, result)
    %i[
      stories_visited downloaded analyzed commented reacted skipped_video skipped_not_tagged
      skipped_ads skipped_invalid_media skipped_unreplyable skipped_interaction_retry skipped_reshared_external_link skipped_out_of_network failed
    ].each do |key|
      totals[key] += result[key].to_i
    end
  end
end
