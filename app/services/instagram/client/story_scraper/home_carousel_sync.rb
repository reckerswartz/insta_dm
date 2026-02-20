module Instagram
  class Client
    module StoryScraper
      module HomeCarouselSync
        def sync_home_story_carousel!(story_limit: 10, auto_reply_only: false)
          limit = story_limit.to_i.clamp(1, 50)
          tagged_only = ActiveModel::Type::Boolean.new.cast(auto_reply_only)

          with_recoverable_session(label: "sync_home_story_carousel") do
            with_authenticated_driver do |driver|
              with_task_capture(
                driver: driver,
                task_name: "home_story_sync_start",
                meta: { story_limit: limit, auto_reply_only: tagged_only }
              ) do
                driver.navigate.to(INSTAGRAM_BASE_URL)
                wait_for(driver, css: "body", timeout: 12)
                dismiss_common_overlays!(driver)
                capture_task_html(driver: driver, task_name: "home_story_sync_home_loaded", status: "ok")

                open_first_story_from_home_carousel!(driver: driver)

                wait_for(driver, css: "body", timeout: 12)
                freeze_story_progress!(driver)
                capture_task_html(driver: driver, task_name: "home_story_sync_opened_first_story", status: "ok")

                stats = SyncStats.new
                visited_refs = {}
                story_api_cache = {}
                safety_limit = limit * 5
                exit_reason = "safety_limit_exhausted"
                account_profile = find_or_create_profile_for_auto_engagement!(username: @account.username)
                started_at = Time.current
                account_profile.record_event!(
                  kind: "story_sync_started",
                  external_id: "story_sync_started:home_carousel:#{started_at.utc.iso8601(6)}",
                  occurred_at: started_at,
                  metadata: { source: "home_story_carousel", story_limit: limit, auto_reply_only: tagged_only }
                )

                safety_limit.times do
                  if stats[:stories_visited] >= limit
                    exit_reason = "limit_reached"
                    break
                  end

                  context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
                  if context[:story_url_recovery_needed]
                    recover_story_url_context!(driver: driver, username: context[:username], reason: "fallback_profile_url")
                    context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
                  end

                  ref = context[:ref].presence || context[:story_key].to_s
                  if ref.blank?
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_story_context_missing",
                      status: "error",
                      meta: {
                        current_url: driver.current_url.to_s,
                        page_title: driver.title.to_s,
                        resolved_username: context[:username],
                        resolved_story_id: context[:story_id]
                      }
                    )
                    fallback_username = context[:username].presence || @account.username.to_s
                    if fallback_username.present?
                      fallback_profile = find_or_create_profile_for_auto_engagement!(username: fallback_username)
                      fallback_profile.record_event!(
                        kind: "story_sync_failed",
                        external_id: "story_sync_failed:context_missing:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: story_sync_failure_metadata(
                          reason: "story_context_missing",
                          error: nil,
                          story_id: nil,
                          story_ref: nil,
                          story_url: driver.current_url.to_s,
                          current_url: driver.current_url.to_s,
                          page_title: driver.title.to_s
                        )
                      )
                    end
                    exit_reason = "story_context_missing"
                    break
                  end
                  story_key = context[:story_key].presence || ref
                  if visited_refs[story_key]
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_duplicate_story_key",
                      status: "error",
                      meta: {
                        story_key: story_key,
                        ref: ref,
                        current_url: driver.current_url.to_s
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    if moved
                      next
                    end
                    exit_reason = "duplicate_story_key_no_progress"
                    break
                  end
                  visited_refs[story_key] = true
                  story_id = normalize_story_id_token(context[:story_id])
                  story_id = normalize_story_id_token(ref.to_s.split(":")[1].to_s) if story_id.blank?
                  story_id = normalize_story_id_token(current_story_reference(driver.current_url.to_s).to_s.split(":")[1].to_s) if story_id.blank?
                  story_url = canonical_story_url(
                    username: context[:username],
                    story_id: story_id,
                    fallback_url: driver.current_url.to_s
                  )

                  stats[:stories_visited] += 1
                  freeze_story_progress!(driver)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_story_loaded",
                    status: "ok",
                    meta: { ref: ref, story_key: story_key, username: context[:username], story_id: story_id, current_url: story_url }
                  )

                  if story_id.blank?
                    stats[:failed] += 1
                    fallback_profile = find_or_create_profile_for_auto_engagement!(username: context[:username].presence || @account.username.to_s)
                    fallback_profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:missing_story_id:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "story_id_unresolved",
                        error: nil,
                        story_id: nil,
                        story_ref: ref,
                        story_url: story_url,
                        story_key: story_key
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  profile = find_story_network_profile(username: context[:username])
                  if profile.nil?
                    stats[:skipped_out_of_network] += 1
                    account_profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: "profile_not_in_network",
                        status: "Out of network",
                        username: context[:username].to_s
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_out_of_network_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        username: context[:username].to_s,
                        reason: "profile_not_in_network"
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  if profile_interaction_retry_pending?(profile)
                    stats[:skipped_interaction_retry] += 1
                    stats[:skipped_unreplyable] += 1
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: "interaction_retry_window_active",
                        status: "Interaction unavailable (retry pending)",
                        retry_after_at: profile.story_interaction_retry_after_at&.iso8601,
                        interaction_state: profile.story_interaction_state.to_s,
                        interaction_reason: profile.story_interaction_reason.to_s
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_interaction_retry_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        retry_after_at: profile.story_interaction_retry_after_at&.iso8601,
                        interaction_state: profile.story_interaction_state.to_s,
                        interaction_reason: profile.story_interaction_reason.to_s
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  media = resolve_story_media_for_current_context(
                    driver: driver,
                    username: context[:username],
                    story_id: story_id,
                    fallback_story_key: story_key,
                    cache: story_api_cache
                  )
                  if media[:url].to_s.blank?
                    stats[:failed] += 1
                    profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "api_story_media_unavailable",
                        error: nil,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_source: media[:source].to_s,
                        media_variant_count: media[:media_variant_count].to_i
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  media_story_id_hint = story_id_hint_from_media_url(media[:url])
                  if media_story_id_hint.present? && media_story_id_hint != story_id
                    stats[:failed] += 1
                    profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "story_media_story_id_mismatch",
                        error: nil,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        expected_story_id: story_id,
                        media_story_id: media_story_id_hint,
                        media_source: media[:source].to_s,
                        media_url: media[:url].to_s
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end
                  ad_context = detect_story_ad_context(driver: driver, media: media)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_story_probe",
                    status: "ok",
                    meta: {
                      story_id: story_id,
                      story_ref: ref,
                      story_key: story_key,
                      username: context[:username],
                      ad_detected: ad_context[:ad_detected],
                      ad_reason: ad_context[:reason],
                      ad_marker_text: ad_context[:marker_text],
                      ad_signal_source: ad_context[:signal_source],
                      ad_signal_confidence: ad_context[:signal_confidence],
                      ad_debug_hint: ad_context[:debug_hint],
                      media_source: media[:source],
                      media_type: media[:media_type],
                      media_url: media[:url].to_s.byteslice(0, 500),
                      media_width: media[:width],
                      media_height: media[:height],
                      media_variant_count: media[:media_variant_count].to_i,
                      primary_media_source: media[:primary_media_source].to_s,
                      primary_media_index: media[:primary_media_index],
                      carousel_media_count: Array(media[:carousel_media]).length
                    }
                  )
                  if ad_context[:ad_detected]
                    stats[:skipped_ads] += 1
                    profile.record_event!(
                      kind: "story_ad_skipped",
                      external_id: "story_ad_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: ad_context[:reason],
                        marker_text: ad_context[:marker_text]
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_ad_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        reason: ad_context[:reason],
                        marker_text: ad_context[:marker_text]
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  api_external_context = story_external_profile_link_context_from_api(
                    username: context[:username],
                    story_id: story_id,
                    cache: story_api_cache
                  )
                  if api_external_context[:known] && api_external_context[:has_external_profile_link]
                    stats[:skipped_reshared_external_link] += 1
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: api_external_context[:reason_code].to_s.presence || "api_external_profile_indicator",
                        status: "External attribution detected (API)",
                        linked_username: api_external_context[:linked_username],
                        linked_profile_url: api_external_context[:linked_profile_url],
                        marker_text: api_external_context[:marker_text],
                        linked_targets: Array(api_external_context[:linked_targets])
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_external_profile_link_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        linked_username: api_external_context[:linked_username],
                        linked_profile_url: api_external_context[:linked_profile_url],
                        marker_text: api_external_context[:marker_text],
                        linked_targets: Array(api_external_context[:linked_targets]),
                        reason_code: api_external_context[:reason_code]
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  api_reply_gate = story_reply_capability_from_api(username: context[:username], story_id: story_id)
                  if api_reply_gate[:known] && api_reply_gate[:reply_possible] == false
                    stats[:skipped_unreplyable] += 1
                    retry_after = Time.current + STORY_INTERACTION_RETRY_DAYS.days
                    mark_profile_interaction_state!(
                      profile: profile,
                      state: "unavailable",
                      reason: api_reply_gate[:reason_code].to_s.presence || "api_can_reply_false",
                      reaction_available: false,
                      retry_after_at: retry_after
                    )
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: api_reply_gate[:reason_code],
                        status: api_reply_gate[:status],
                        retry_after_at: retry_after.iso8601
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  reply_gate =
                    if api_reply_gate[:known] && api_reply_gate[:reply_possible] == true
                      { reply_possible: true, reason_code: nil, status: api_reply_gate[:status], marker_text: "", submission_reason: "api_can_reply_true" }
                    else
                      check_story_reply_capability(driver: driver)
                    end
                  unless reply_gate[:reply_possible]
                    reaction_result = react_to_story_if_available!(driver: driver)
                    if reaction_result[:reacted]
                      stats[:reacted] += 1
                      mark_profile_interaction_state!(
                        profile: profile,
                        state: "reaction_only",
                        reason: reply_gate[:reason_code].to_s.presence || "reply_unavailable_reaction_available",
                        reaction_available: true
                      )
                      profile.record_event!(
                        kind: "story_reaction_sent",
                        external_id: "story_reaction_sent:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          reaction_reason: reaction_result[:reason],
                          reaction_marker_text: reaction_result[:marker_text],
                          reply_gate_reason: reply_gate[:reason_code]
                        }
                      )
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_reaction_fallback_sent",
                        status: "ok",
                        meta: {
                          story_id: story_id,
                          story_ref: ref,
                          reaction_reason: reaction_result[:reason],
                          reaction_marker_text: reaction_result[:marker_text],
                          reply_gate_reason: reply_gate[:reason_code]
                        }
                      )
                      moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                      unless moved
                        exit_reason = "next_navigation_failed"
                        break
                      end
                      next
                    end

                    stats[:skipped_unreplyable] += 1
                    retry_after = Time.current + STORY_INTERACTION_RETRY_DAYS.days
                    mark_profile_interaction_state!(
                      profile: profile,
                      state: "unavailable",
                      reason: reply_gate[:reason_code].to_s.presence || "reply_unavailable",
                      reaction_available: false,
                      retry_after_at: retry_after
                    )
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: reply_gate[:reason_code],
                        status: reply_gate[:status],
                        submission_reason: reply_gate[:submission_reason],
                        submission_marker_text: reply_gate[:marker_text],
                        retry_after_at: retry_after.iso8601,
                        reaction_fallback_attempted: true,
                        reaction_fallback_reason: reaction_result[:reason],
                        reaction_fallback_marker_text: reaction_result[:marker_text]
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_reply_precheck_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        reason: reply_gate[:reason_code],
                        status_text: reply_gate[:status],
                        marker_text: reply_gate[:marker_text],
                        retry_after_at: retry_after.iso8601,
                        reaction_fallback_reason: reaction_result[:reason],
                        reaction_fallback_marker_text: reaction_result[:marker_text]
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end
                  mark_profile_interaction_state!(
                    profile: profile,
                    state: "reply_available",
                    reason: "reply_box_found",
                    reaction_available: nil,
                    retry_after_at: nil
                  )

                  story_time = Time.current
                  profile.record_event!(
                    kind: "story_uploaded",
                    external_id: "story_uploaded:#{story_id}",
                    occurred_at: nil,
                    metadata: {
                      source: "home_story_carousel",
                      story_id: story_id,
                      story_ref: ref,
                      story_url: story_url
                    }
                  )
                  profile.record_event!(
                    kind: "story_viewed",
                    external_id: "story_viewed:#{story_id}:#{story_time.utc.iso8601(6)}",
                    occurred_at: story_time,
                    metadata: {
                      source: "home_story_carousel",
                      story_id: story_id,
                      story_ref: ref,
                      story_url: story_url
                    }
                  )
                  reused_download = load_story_download_media_for_profile(profile: profile, story_id: story_id)
                  media_download_url = normalize_story_media_download_url(media[:url])

                  if media[:media_type].to_s == "video"
                    begin
                      raise "Invalid media URL" if !reused_download && media_download_url.blank?

                      download = reused_download || download_media_with_metadata(url: media_download_url, user_agent: @account.user_agent)
                      stats[:downloaded] += 1 unless reused_download
                      now = Time.current
                      downloaded_event = profile.record_event!(
                        kind: "story_downloaded",
                        external_id: story_download_external_id(story_id),
                        occurred_at: now,
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          media_type: "video",
                          media_source: media[:source],
                          media_url: media_download_url,
                          image_url: media[:image_url],
                          video_url: media[:video_url],
                          media_width: media[:width],
                          media_height: media[:height],
                          owner_user_id: media[:owner_user_id],
                          owner_username: media[:owner_username],
                          api_media_variant_count: media[:media_variant_count].to_i,
                          api_primary_media_source: media[:primary_media_source].to_s,
                          api_primary_media_index: media[:primary_media_index],
                          api_carousel_media: compact_story_media_variants_for_metadata(media[:carousel_media]),
                          media_content_type: download[:content_type],
                          media_bytes: download[:bytes].bytesize
                        }
                      )
                      attach_download_to_event(event: downloaded_event, download: download)
                      InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)
                      StoryIngestionService.new(account: @account, profile: profile).ingest!(
                        story: {
                          story_id: story_id,
                          media_type: "video",
                          media_url: media_download_url,
                          image_url: nil,
                          video_url: media[:url],
                          caption: nil,
                          permalink: story_url,
                          taken_at: story_time
                        },
                        source_event: downloaded_event,
                        bytes: download[:bytes],
                        content_type: download[:content_type],
                        filename: download[:filename]
                      )
                    rescue StandardError => e
                      stats[:failed] += 1
                      profile.record_event!(
                        kind: "story_sync_failed",
                        external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: story_sync_failure_metadata(
                          reason: "media_download_failed",
                          error: e,
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          media_url: media[:url]
                        )
                      )
                    end
                    stats[:skipped_video] += 1
                    next unless click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    next
                  end

                  duplicate_reply = story_already_replied?(
                    profile: profile,
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    media_url: media[:url]
                  )
                  if duplicate_reply[:found]
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: "duplicate_story_already_replied",
                        matched_by: duplicate_reply[:matched_by],
                        matched_event_external_id: duplicate_reply[:matched_external_id]
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_duplicate_reply_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        matched_by: duplicate_reply[:matched_by],
                        matched_event_external_id: duplicate_reply[:matched_external_id]
                      }
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  begin
                    raise "Invalid media URL" if !reused_download && media_download_url.blank?

                    download = reused_download || download_media_with_metadata(url: media_download_url, user_agent: @account.user_agent)
                    stats[:downloaded] += 1 unless reused_download
                    quality = evaluate_story_image_quality(download: download, media: media)
                    if quality[:skip]
                      stats[:skipped_invalid_media] += 1
                      profile.record_event!(
                        kind: "story_reply_skipped",
                        external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          reason: "invalid_story_media",
                          quality_reason: quality[:reason],
                          quality_entropy: quality[:entropy],
                          media_type: media[:media_type],
                          media_width: media[:width],
                          media_height: media[:height],
                          media_content_type: download[:content_type],
                          media_bytes: download[:bytes].bytesize
                        }
                      )
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_invalid_media_skipped",
                        status: "ok",
                        meta: {
                          story_id: story_id,
                          story_ref: ref,
                          quality_reason: quality[:reason],
                          quality_entropy: quality[:entropy],
                          media_content_type: download[:content_type],
                          media_bytes: download[:bytes].bytesize
                        }
                      )
                      moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                      unless moved
                        exit_reason = "next_navigation_failed"
                        break
                      end
                      next
                    end
                    now = Time.current
                    downloaded_event = profile.record_event!(
                      kind: "story_downloaded",
                      external_id: story_download_external_id(story_id),
                      occurred_at: now,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_type: "image",
                        media_source: media[:source],
                        media_url: media_download_url,
                        image_url: media[:image_url],
                        video_url: media[:video_url],
                        media_width: media[:width],
                        media_height: media[:height],
                        owner_user_id: media[:owner_user_id],
                        owner_username: media[:owner_username],
                        api_media_variant_count: media[:media_variant_count].to_i,
                        api_primary_media_source: media[:primary_media_source].to_s,
                        api_primary_media_index: media[:primary_media_index],
                        api_carousel_media: compact_story_media_variants_for_metadata(media[:carousel_media]),
                        media_content_type: download[:content_type],
                        media_bytes: download[:bytes].bytesize
                      }
                    )
                    attach_download_to_event(event: downloaded_event, download: download)
                    InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)

                    payload = build_auto_engagement_post_payload(
                      profile: profile,
                      shortcode: story_id,
                      caption: nil,
                      permalink: story_url,
                      include_story_history: true
                    )
                    analysis = analyze_for_auto_engagement!(
                      analyzable: downloaded_event,
                      payload: payload,
                      bytes: download[:bytes],
                      content_type: download[:content_type],
                      source_url: media_download_url
                    )
                    stats[:analyzed] += 1 if analysis.present?

                    suggestions = generate_comment_suggestions_from_analysis!(profile: profile, payload: payload, analysis: analysis)
                    comment_text = suggestions.first.to_s.strip
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_comment_generation",
                      status: comment_text.present? ? "ok" : "error",
                      meta: { story_ref: ref, suggestions_count: suggestions.length, comment_preview: comment_text.byteslice(0, 120) }
                    )

                    if tagged_only && !profile_auto_reply_enabled?(profile)
                      stats[:skipped_not_tagged] += 1
                      profile.record_event!(
                        kind: "story_reply_skipped",
                        external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: { source: "home_story_carousel", story_id: story_id, story_ref: ref, story_url: story_url, reason: "missing_auto_reply_tag" }
                      )
                    elsif comment_text.blank?
                      profile.record_event!(
                        kind: "story_reply_skipped",
                        external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: { source: "home_story_carousel", story_id: story_id, story_ref: ref, story_url: story_url, reason: "no_comment_generated" }
                      )
                    else
                      comment_result = comment_on_story_via_api!(
                        story_id: story_id,
                        story_username: context[:username],
                        comment_text: comment_text
                      )
                      if !comment_result[:posted]
                        comment_result = comment_on_story_via_ui!(driver: driver, comment_text: comment_text)
                      end
                      posted = comment_result[:posted]
                      skip_status = story_reply_skip_status_for(comment_result)
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_comment_submission",
                        status: posted ? "ok" : "error",
                        meta: {
                          story_ref: ref,
                          comment_preview: comment_text.byteslice(0, 120),
                          posted: posted,
                          submission_method: comment_result[:method],
                          failure_reason: comment_result[:reason],
                          skip_status: skip_status[:status],
                          skip_reason_code: skip_status[:reason_code]
                        }
                      )
                      if posted
                        stats[:commented] += 1
                        mark_profile_interaction_state!(
                          profile: profile,
                          state: "reply_available",
                          reason: "comment_sent",
                          reaction_available: nil,
                          retry_after_at: nil
                        )
                        profile.record_event!(
                          kind: "story_reply_sent",
                          external_id: "story_reply_sent:#{story_id}",
                          occurred_at: Time.current,
                          metadata: {
                            source: "home_story_carousel",
                            story_id: story_id,
                            story_ref: ref,
                            story_url: story_url,
                            media_url: media[:url],
                            comment_text: comment_text,
                            submission_method: comment_result[:method]
                          }
                        )
                        attach_reply_comment_to_downloaded_event!(downloaded_event: downloaded_event, comment_text: comment_text)
                      else
                        profile.record_event!(
                          kind: "story_reply_skipped",
                          external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                          occurred_at: Time.current,
                          metadata: {
                            source: "home_story_carousel",
                            story_id: story_id,
                            story_ref: ref,
                            story_url: story_url,
                            reason: skip_status[:reason_code],
                            status: skip_status[:status],
                            submission_reason: comment_result[:reason],
                            submission_marker_text: comment_result[:marker_text]
                          }
                        )
                      end
                    end
                  rescue StandardError => e
                    stats[:failed] += 1
                    profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "story_processing_failed",
                        error: e,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_url: media[:url]
                      )
                    )
                  end

                  moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                  unless moved
                    exit_reason = "next_navigation_failed"
                    break
                  end
                end

                if stats[:stories_visited].zero?
                  stats[:failed] += 1
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_no_progress",
                    status: "error",
                    meta: {
                      reason: "loop_exited_without_story_processing",
                      current_url: driver.current_url.to_s,
                      page_title: driver.title.to_s,
                      stats: stats
                    }
                  )
                  account_profile.record_event!(
                    kind: "story_sync_failed",
                    external_id: "story_sync_failed:no_progress:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: story_sync_failure_metadata(
                      reason: "loop_exited_without_story_processing",
                      error: nil,
                      story_id: nil,
                      story_ref: nil,
                      story_url: driver.current_url.to_s,
                      current_url: driver.current_url.to_s,
                      page_title: driver.title.to_s
                    )
                  )
                end
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_end_state",
                  status: "ok",
                  meta: {
                    reason: exit_reason,
                    story_limit: limit,
                    stats: stats,
                    current_url: driver.current_url.to_s
                  }
                )
                account_profile.record_event!(
                  kind: "story_sync_completed",
                  external_id: "story_sync_completed:home_carousel:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_limit: limit,
                    auto_reply_only: tagged_only,
                    stats: stats,
                    end_reason: exit_reason
                  }
                )

                stats
              end
            end
          end
        end

        private

        def story_download_external_id(story_id)
          "story_downloaded:#{story_id.to_s.strip}"
        end

        def normalize_story_media_download_url(url)
          value = url.to_s.strip
          return nil if value.blank?
          return value if value.start_with?("http://", "https://")
          return nil if value.start_with?("data:")
          return nil if value.match?(/\A[a-z][a-z0-9+\-.]*:/i)

          URI.join(INSTAGRAM_BASE_URL, value).to_s
        rescue URI::InvalidURIError, ArgumentError
          nil
        end

        def story_sync_failure_metadata(reason:, error:, story_id:, story_ref:, story_url:, media_url: nil, **extra)
          payload = {
            source: "home_story_carousel",
            reason: reason.to_s,
            failure_category: classify_story_sync_failure(error: error, reason: reason),
            retryable: transient_story_sync_failure?(error),
            story_id: story_id.to_s,
            story_ref: story_ref.to_s,
            story_url: story_url.to_s,
            media_url: media_url.to_s.presence,
            error_class: error&.class&.name,
            error_message: error&.message.to_s&.byteslice(0, 500)
          }.compact
          payload.merge!(extra.compact)
          payload
        end

        def classify_story_sync_failure(error:, reason: nil)
          message = error&.message.to_s&.downcase.to_s
          normalized_reason = reason.to_s.downcase
          return "network" if transient_story_sync_failure?(error)
          return "session" if message.include?("login") || message.include?("cookie") || message.include?("csrf")
          return "parsing" if normalized_reason.include?("story_id_unresolved") || normalized_reason.include?("context_missing")
          return "media_fetch" if message.include?("media") || message.include?("invalid media url") || message.include?("http")
          return "media_fetch" if normalized_reason.include?("media")

          "unknown"
        end

        def transient_story_sync_failure?(error)
          return false unless error

          return true if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
          return true if error.is_a?(Errno::ECONNRESET) || error.is_a?(Errno::ECONNREFUSED)
          return true if defined?(Timeout::Error) && error.is_a?(Timeout::Error)

          msg = error.message.to_s.downcase
          msg.include?("timeout") || msg.include?("http 429") || msg.include?("http 502") || msg.include?("http 503") || msg.include?("http 504")
        end

        def attach_media_to_event(event, bytes:, filename:, content_type:)
          return unless event
          return if event.media.attached?

          event.media.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
        rescue StandardError
          nil
        end

        def attach_download_to_event(event:, download:)
          return unless event
          return if event.media.attached?

          blob = download.is_a?(Hash) ? download[:blob] : nil
          if blob.present?
            event.media.attach(blob)
            return
          end

          attach_media_to_event(
            event,
            bytes: download[:bytes],
            filename: download[:filename],
            content_type: download[:content_type]
          )
        rescue StandardError
          nil
        end

        def load_story_download_media_for_profile(profile:, story_id:)
          sid = story_id.to_s.strip
          return nil if sid.blank?

          event = profile.instagram_profile_events
            .joins(:media_attachment)
            .with_attached_media
            .where(kind: "story_downloaded")
            .where("metadata ->> 'story_id' = ?", sid)
            .order(detected_at: :desc, id: :desc)
            .first
          return media_download_payload_for_event(event) if event&.media&.attached?

          escaped_story_id = ActiveRecord::Base.sanitize_sql_like(sid)
          legacy_event = profile.instagram_profile_events
            .joins(:media_attachment)
            .with_attached_media
            .where(kind: "story_downloaded")
            .where("external_id LIKE ?", "story_downloaded:#{escaped_story_id}:%")
            .order(detected_at: :desc, id: :desc)
            .first
          return media_download_payload_for_event(legacy_event) if legacy_event&.media&.attached?

          story_record = profile.instagram_stories
            .joins(:media_attachment)
            .where(story_id: sid)
            .order(taken_at: :desc, id: :desc)
            .first
          return nil unless story_record&.media&.attached?

          blob = story_record.media.blob
          {
            blob: blob,
            bytes: blob.download,
            content_type: blob.content_type.to_s.presence || "application/octet-stream",
            filename: blob.filename.to_s.presence || "story_#{story_record.id}.bin"
          }
        rescue StandardError
          nil
        end

        def media_download_payload_for_event(event)
          return nil unless event&.media&.attached?

          blob = event.media.blob
          {
            blob: blob,
            bytes: blob.download,
            content_type: blob.content_type.to_s.presence || "application/octet-stream",
            filename: blob.filename.to_s.presence || "story_#{event.id}.bin"
          }
        rescue StandardError
          nil
        end
      end
    end
  end
end
