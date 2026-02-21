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
                if respond_to?(:use_api_story_sync_flow?) && use_api_story_sync_flow?
                  next sync_home_story_carousel_via_api!(
                    driver: driver,
                    limit: limit,
                    tagged_only: tagged_only
                  )
                end

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
                story_id_username_map = {}
                story_api_cache = {}
                safety_limit = [ limit * 12, 80 ].max
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

                  gate = click_story_view_gate_if_present!(driver: driver)
                  if gate[:clicked]
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_view_gate_acknowledged",
                      status: "ok",
                      meta: {
                        current_url: driver.current_url.to_s,
                        gate_label: gate[:label],
                        gate_reason: gate[:reason],
                        gate_prompt_text: gate[:prompt_text]
                      }
                    )
                  elsif gate[:present]
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_view_gate_blocked",
                      status: "error",
                      meta: {
                        current_url: driver.current_url.to_s,
                        gate_reason: gate[:reason],
                        gate_prompt_text: gate[:prompt_text]
                      }
                    )
                  end

                  context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
                  if context[:story_url_recovery_needed]
                    recover_story_url_context!(driver: driver, username: context[:username], reason: "fallback_profile_url")
                    context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
                  end

                  ref = context[:ref].presence || context[:story_key].to_s
                  gate_retry = nil
                  if ref.blank?
                    gate_retry = click_story_view_gate_if_present!(driver: driver)
                    if gate_retry[:clicked]
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_view_gate_acknowledged_retry",
                        status: "ok",
                        meta: {
                          current_url: driver.current_url.to_s,
                          gate_label: gate_retry[:label],
                          gate_reason: gate_retry[:reason],
                          gate_prompt_text: gate_retry[:prompt_text]
                        }
                      )
                    elsif gate_retry[:present]
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_view_gate_retry_blocked",
                        status: "error",
                        meta: {
                          current_url: driver.current_url.to_s,
                          gate_reason: gate_retry[:reason],
                          gate_prompt_text: gate_retry[:prompt_text]
                        }
                      )
                    end
                    if gate_retry[:clicked] || gate_retry[:present]
                      freeze_story_progress!(driver)
                      context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
                      ref = context[:ref].presence || context[:story_key].to_s
                    end
                  end
                  if ref.blank?
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_story_context_missing",
                      status: "error",
                      meta: {
                        current_url: driver.current_url.to_s,
                        page_title: driver.title.to_s,
                        resolved_username: context[:username],
                        resolved_story_id: context[:story_id],
                        gate_present: ActiveModel::Type::Boolean.new.cast(gate_retry&.dig(:present)),
                        gate_reason: gate_retry&.dig(:reason),
                        gate_prompt_text: gate_retry&.dig(:prompt_text)
                      }
                    )
                    fallback_username = context[:username].presence || @account.username.to_s
                    if fallback_username.present?
                      fallback_profile = find_or_create_profile_for_auto_engagement!(username: fallback_username)
                      reason =
                        if story_page_unavailable?(driver)
                          "story_page_unavailable"
                        elsif gate_retry&.dig(:present) && !gate_retry&.dig(:cleared)
                          "story_view_gate_not_cleared"
                        elsif gate_retry&.dig(:present)
                          "story_context_missing_after_view_gate"
                        else
                          "story_context_missing"
                        end
                      status =
                        case reason
                        when "story_page_unavailable"
                          "Story unavailable or expired"
                        when "story_view_gate_not_cleared"
                          "Story blocked by view confirmation gate"
                        when "story_context_missing_after_view_gate"
                          "Story context missing after view gate"
                        else
                          "Story context missing"
                        end
                      fallback_profile.record_event!(
                        kind: "story_sync_failed",
                        external_id: "story_sync_failed:context_missing:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: story_sync_failure_metadata(
                          reason: reason,
                          error: nil,
                          story_id: nil,
                          story_ref: nil,
                          story_url: driver.current_url.to_s,
                          current_url: driver.current_url.to_s,
                          page_title: driver.title.to_s,
                          status: status,
                          reference_url: driver.current_url.to_s,
                          gate_reason: gate_retry&.dig(:reason),
                          gate_prompt_text: gate_retry&.dig(:prompt_text),
                          gate_present: ActiveModel::Type::Boolean.new.cast(gate_retry&.dig(:present))
                        )
                      )
                    end
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: context[:ref].to_s)
                    unless moved
                      exit_reason = "story_context_missing"
                      break
                    end
                    next
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
                  media_probe = nil
                  if story_id.blank?
                    media_probe = resolve_story_media_with_retry(
                      driver: driver,
                      username: context[:username],
                      story_id: "",
                      fallback_story_key: story_key,
                      cache: story_api_cache
                    )
                    story_id = resolve_story_id_for_processing(
                      current_story_id: story_id,
                      ref: ref,
                      live_url: driver.current_url.to_s,
                      media: media_probe[:media]
                    )
                  end
                  story_url = canonical_story_url(
                    username: context[:username],
                    story_id: story_id,
                    fallback_url: driver.current_url.to_s
                  )

                  freeze_story_progress!(driver)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_story_loaded",
                    status: "ok",
                    meta: { ref: ref, story_key: story_key, username: context[:username], story_id: story_id, current_url: story_url }
                  )

                  if story_id.blank?
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
                        story_key: story_key,
                        **story_media_resolution_metadata(media_probe)
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  if media_probe.blank? || media_probe.dig(:media, :url).to_s.blank?
                    media_probe = resolve_story_media_with_retry(
                      driver: driver,
                      username: context[:username],
                      story_id: story_id,
                      fallback_story_key: story_key,
                      cache: story_api_cache
                    )
                  end
                  media = media_probe[:media].is_a?(Hash) ? media_probe[:media] : {}
                  if media[:url].to_s.blank?
                    failure_profile = find_story_network_profile(username: context[:username]) || account_profile
                    failure_profile.record_event!(
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
                        media_variant_count: media[:media_variant_count].to_i,
                        **story_media_resolution_metadata(media_probe)
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
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_story_id_reconciled_from_media",
                      status: "ok",
                      meta: {
                        expected_story_id: story_id,
                        media_story_id: media_story_id_hint,
                        story_ref: ref,
                        story_url: story_url,
                        media_source: media[:source].to_s
                      }
                    )
                    story_id = media_story_id_hint
                    ref = "#{context[:username]}:#{story_id}" if context[:username].present?
                    story_url = canonical_story_url(
                      username: context[:username],
                      story_id: story_id,
                      fallback_url: driver.current_url.to_s
                    )
                  end

                  assignment = resolve_story_assignment_context(
                    context_username: context[:username],
                    story_id: story_id,
                    canonical_story_url: story_url,
                    live_story_url: driver.current_url.to_s,
                    media_owner_username: media[:owner_username]
                  )
                  unless assignment[:ok]
                    stats[:failed] += 1 unless assignment[:reason_code].to_s == "story_id_live_url_conflict"
                    failure_profile = find_story_network_profile(username: context[:username]) || account_profile
                    failure_profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: assignment[:reason_code].to_s.presence || "story_assignment_unresolved",
                        error: nil,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        live_story_url: driver.current_url.to_s,
                        context_username: context[:username].to_s,
                        assignment_username: assignment[:username].to_s,
                        assignment_conflict: assignment[:conflict] == true
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  story_username = assignment[:username].to_s
                  story_id = assignment[:story_id].to_s
                  story_url = assignment[:story_url].to_s
                  ref = assignment[:story_ref].to_s.presence || ref

                  normalized_story_username = normalize_username(story_username)
                  existing_story_username = story_id_username_map[story_id].to_s
                  if story_id.present? && existing_story_username.present? && existing_story_username != normalized_story_username
                    stats[:failed] += 1
                    failure_profile = find_story_network_profile(username: story_username) || account_profile
                    failure_profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "story_id_username_conflict_in_run",
                        error: nil,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        live_story_url: driver.current_url.to_s,
                        existing_story_username: existing_story_username,
                        conflicting_story_username: normalized_story_username
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end
                  story_id_username_map[story_id] = normalized_story_username if story_id.present? && normalized_story_username.present?

                  unless media[:source].to_s == "api_reels_media" || story_live_context_matches_assignment?(
                    live_story_url: driver.current_url.to_s,
                    story_username: story_username,
                    story_id: story_id
                  )
                    stats[:failed] += 1
                    live_identity = story_url_identity(driver.current_url.to_s)
                    failure_profile = find_story_network_profile(username: story_username) || account_profile
                    failure_profile.record_event!(
                      kind: "story_sync_failed",
                      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: story_sync_failure_metadata(
                        reason: "story_live_context_unstable",
                        error: nil,
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        live_story_url: driver.current_url.to_s,
                        live_story_username: normalize_username(live_identity[:username].to_s),
                        live_story_id: normalize_story_id_token(live_identity[:story_id].to_s),
                        media_source: media[:source].to_s
                      )
                    )
                    moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                    unless moved
                      exit_reason = "next_navigation_failed"
                      break
                    end
                    next
                  end

                  stats[:stories_visited] += 1
                  network_profile = find_story_network_profile(username: story_username)
                  profile = network_profile || find_or_create_profile_for_auto_engagement!(username: story_username)
                  out_of_network_profile = network_profile.nil?

                  ad_context = detect_story_ad_context(driver: driver, media: media)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_story_probe",
                    status: "ok",
                    meta: {
                      story_id: story_id,
                      story_ref: ref,
                      story_key: story_key,
                      username: story_username,
                      context_username: context[:username].to_s,
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
                    (profile || account_profile).record_event!(
                      kind: "story_ad_skipped",
                      external_id: "story_ad_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_url: media[:url],
                        media_source: media[:source],
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

                  existing_story_download = find_existing_story_download_for_profile(profile: profile, story_id: story_id)
                  if existing_story_download
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_url: media[:url],
                        media_source: media[:source],
                        reason: "duplicate_story_already_downloaded",
                        matched_event_external_id: existing_story_download.external_id.to_s,
                        matched_event_id: existing_story_download.id
                      }
                    )
                    capture_task_html(
                      driver: driver,
                      task_name: "home_story_sync_duplicate_story_download_skipped",
                      status: "ok",
                      meta: {
                        story_id: story_id,
                        story_ref: ref,
                        matched_event_external_id: existing_story_download.external_id.to_s,
                        matched_event_id: existing_story_download.id
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
                    username: story_username,
                    story_id: story_id,
                    cache: story_api_cache,
                    driver: driver
                  )
                  validation_requested_at = Time.current
                  validation_job = ValidateStoryReplyEligibilityJob.perform_later(
                    instagram_account_id: @account.id,
                    instagram_profile_id: profile.id,
                    story_username: story_username,
                    story_id: story_id,
                    api_reply_gate: api_external_context[:reply_gate]
                  )
                  eligibility = {
                    eligible: profile.story_reply_allowed?,
                    reason_code: profile.story_reply_allowed? ? nil : "eligibility_pending_async_validation",
                    status: profile.story_reply_allowed? ? "Eligible" : "Pending async story reply validation",
                    retry_after_at: profile.story_interaction_retry_after_at&.iso8601,
                    interaction_retry_active: profile.story_reply_retry_pending?,
                    interaction_state: profile.story_interaction_state.to_s,
                    interaction_reason: profile.story_interaction_reason.to_s,
                    api_reply_gate: api_external_context[:reply_gate].is_a?(Hash) ? api_external_context[:reply_gate] : {
                      known: false,
                      reply_possible: nil,
                      reason_code: nil,
                      status: "Unknown"
                    },
                    validation_job_id: validation_job.job_id,
                    validation_requested_at: validation_requested_at.iso8601(3)
                  }
                  interaction_retry_active = ActiveModel::Type::Boolean.new.cast(eligibility[:interaction_retry_active])
                  interaction_retry_after_at = eligibility[:retry_after_at].to_s.presence
                  interaction_state = eligibility[:interaction_state].to_s
                  interaction_reason = eligibility[:interaction_reason].to_s
                  api_reply_gate = eligibility[:api_reply_gate].is_a?(Hash) ? eligibility[:api_reply_gate] : {}

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
                      attached = attach_download_to_event(event: downloaded_event, download: download)
                      raise "story_media_attach_failed" unless attached
                      InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)
                      stamp_story_assignment_validation!(
                        downloaded_event: downloaded_event,
                        profile: profile,
                        story_id: story_id,
                        story_url: story_url,
                        story_username: story_username,
                        media: media,
                        cache: story_api_cache,
                        driver: driver
                      )
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
                        media_url: media[:url],
                        media_source: media[:source],
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
                          media_url: media[:url],
                          media_source: media[:source],
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
                    attached = attach_download_to_event(event: downloaded_event, download: download)
                    raise "story_media_attach_failed" unless attached
                    InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)
                    stamp_story_assignment_validation!(
                      downloaded_event: downloaded_event,
                      profile: profile,
                      story_id: story_id,
                      story_url: story_url,
                      story_username: story_username,
                      media: media,
                      cache: story_api_cache,
                      driver: driver
                    )
                    archive_link = archive_link_metadata(downloaded_event: downloaded_event)

                    if out_of_network_profile
                      stats[:skipped_out_of_network] += 1
                      profile.record_event!(
                        kind: "story_reply_skipped",
                        external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: "profile_not_in_network",
                          status: "Out of network",
                          username: story_username
                        }.merge(archive_link)
                      )
                      capture_task_html(
                        driver: driver,
                        task_name: "home_story_sync_out_of_network_archived",
                        status: "ok",
                        meta: {
                          story_id: story_id,
                          story_ref: ref,
                          username: story_username,
                          reason: "profile_not_in_network",
                          media_url: media[:url].to_s.byteslice(0, 220),
                          archive_event_id: downloaded_event.id
                        }
                      )
                      moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                      unless moved
                        exit_reason = "next_navigation_failed"
                        break
                      end
                      next
                    end

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
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: "missing_auto_reply_tag"
                        }.merge(archive_link)
                      )
                    elsif comment_text.blank?
                      profile.record_event!(
                        kind: "story_reply_skipped",
                        external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                        occurred_at: Time.current,
                        metadata: {
                          source: "home_story_carousel",
                          story_id: story_id,
                          story_ref: ref,
                          story_url: story_url,
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: "no_comment_generated"
                        }.merge(archive_link)
                      )
                    elsif interaction_retry_active
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
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: "interaction_retry_window_active",
                          status: "Interaction unavailable (retry pending)",
                          retry_after_at: interaction_retry_after_at,
                          interaction_state: interaction_state,
                          interaction_reason: interaction_reason
                        }.merge(archive_link)
                      )
                    elsif api_external_context[:known] && api_external_context[:has_external_profile_link]
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
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: api_external_context[:reason_code].to_s.presence || "api_external_profile_indicator",
                          status: "External attribution detected (API)",
                          linked_username: api_external_context[:linked_username],
                          linked_profile_url: api_external_context[:linked_profile_url],
                          marker_text: api_external_context[:marker_text],
                          linked_targets: Array(api_external_context[:linked_targets])
                        }.merge(archive_link)
                      )
                    elsif eligibility[:eligible] == false
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
                          media_url: media[:url],
                          media_source: media[:source],
                          reason: eligibility[:reason_code],
                          status: eligibility[:status],
                          retry_after_at: eligibility[:retry_after_at]
                        }.merge(archive_link)
                      )
                    else
                      reply_gate =
                        if api_reply_gate[:known] && api_reply_gate[:reply_possible] == true
                          { reply_possible: true, reason_code: nil, status: api_reply_gate[:status], marker_text: "", submission_reason: "api_can_reply_true" }
                        else
                          check_story_reply_capability(driver: driver)
                        end

                      if !reply_gate[:reply_possible]
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
                              media_url: media[:url],
                              reaction_reason: reaction_result[:reason],
                              reaction_marker_text: reaction_result[:marker_text],
                              reply_gate_reason: reply_gate[:reason_code]
                            }.merge(archive_link)
                          )
                        else
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
                              media_url: media[:url],
                              media_source: media[:source],
                              reason: reply_gate[:reason_code],
                              status: reply_gate[:status],
                              submission_reason: reply_gate[:submission_reason],
                              submission_marker_text: reply_gate[:marker_text],
                              retry_after_at: retry_after.iso8601,
                              reaction_fallback_attempted: true,
                              reaction_fallback_reason: reaction_result[:reason],
                              reaction_fallback_marker_text: reaction_result[:marker_text]
                            }.merge(archive_link)
                          )
                        end
                      else
                        mark_profile_interaction_state!(
                          profile: profile,
                          state: "reply_available",
                          reason: "reply_box_found",
                          reaction_available: nil,
                          retry_after_at: nil
                        )

                        enqueue_result = enqueue_story_reply_delivery!(
                          profile: profile,
                          story_id: story_id,
                          comment_text: comment_text,
                          downloaded_event: downloaded_event,
                          metadata: {
                            source: "home_story_carousel",
                            story_id: story_id,
                            story_ref: ref,
                            story_url: story_url,
                            media_url: media[:url],
                            eligibility_validation_job_id: eligibility[:validation_job_id],
                            eligibility_validation_requested_at: eligibility[:validation_requested_at],
                            eligibility_interaction_state: interaction_state.presence,
                            eligibility_interaction_reason: interaction_reason.presence
                          }.merge(archive_link)
                        )
                        capture_task_html(
                          driver: driver,
                          task_name: "home_story_sync_comment_submission",
                          status: enqueue_result[:queued] ? "ok" : "error",
                          meta: {
                            story_ref: ref,
                            comment_preview: comment_text.byteslice(0, 120),
                            posted: false,
                            queued: enqueue_result[:queued],
                            queue_name: enqueue_result[:queue_name],
                            active_job_id: enqueue_result[:job_id],
                            failure_reason: enqueue_result[:reason]
                          }
                        )
                        if enqueue_result[:queued]
                          stats[:commented] += 1
                          mark_profile_interaction_state!(
                            profile: profile,
                            state: "reply_available",
                            reason: "comment_queued",
                            reaction_available: nil,
                            retry_after_at: nil
                          )
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
                              media_url: media[:url],
                              media_source: media[:source],
                              reason: enqueue_result[:reason].to_s.presence || "reply_enqueue_failed",
                              status: "Reply queued asynchronously",
                              queue_name: enqueue_result[:queue_name],
                              active_job_id: enqueue_result[:job_id]
                            }.merge(archive_link)
                          )
                        end
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

        def find_existing_story_download_for_profile(profile:, story_id:)
          sid = story_id.to_s.strip
          return nil if sid.blank?

          escaped_story_id = ActiveRecord::Base.sanitize_sql_like(sid)
          profile.instagram_profile_events
            .joins(:media_attachment)
            .with_attached_media
            .where(kind: "story_downloaded")
            .where(
              "(metadata ->> 'story_id' = :sid) OR (external_id = :exact_id) OR (external_id LIKE :legacy_prefix)",
              sid: sid,
              exact_id: story_download_external_id(sid),
              legacy_prefix: "story_downloaded:#{escaped_story_id}:%"
            )
            .order(detected_at: :desc, id: :desc)
            .first
        rescue StandardError
          nil
        end

        def resolve_story_media_with_retry(driver:, username:, story_id:, fallback_story_key:, cache:)
          attempts = []
          media = nil

          3.times do |idx|
            attempt_number = idx + 1
            media = resolve_story_media_for_current_context(
              driver: driver,
              username: username,
              story_id: story_id,
              fallback_story_key: fallback_story_key,
              cache: cache
            )
            attempts << {
              attempt: attempt_number,
              source: media[:source].to_s,
              resolved: media[:url].to_s.present?
            }
            break if media[:url].to_s.present?
            break if attempt_number >= 3

            freeze_story_progress!(driver)
            sleep(0.25 * attempt_number)
            if attempt_number == 2 && username.to_s.present?
              recover_story_url_context!(driver: driver, username: username, reason: "media_resolution_retry")
            end
          end

          api_failure = story_api_recent_failure_for(username: username)
          {
            media: media || {},
            attempts: attempts,
            api_rate_limited: ActiveModel::Type::Boolean.new.cast(api_failure&.dig(:rate_limited)),
            api_failure: api_failure
          }
        rescue StandardError => e
          {
            media: {},
            attempts: attempts || [],
            api_rate_limited: story_api_rate_limited_for?(username: username),
            api_failure: story_api_recent_failure_for(username: username),
            media_resolution_error_class: e.class.name,
            media_resolution_error_message: e.message.to_s.byteslice(0, 220)
          }
        end

        def resolve_story_id_for_processing(current_story_id:, ref:, live_url:, media:)
          candidates = []
          candidates << normalize_story_id_token(current_story_id)
          candidates << normalize_story_id_token(ref.to_s.split(":")[1].to_s)
          candidates << normalize_story_id_token(current_story_reference(live_url.to_s).to_s.split(":")[1].to_s)
          if media.is_a?(Hash)
            candidates << normalize_story_id_token(media[:story_id].to_s)
            candidates << normalize_story_id_token(story_id_hint_from_media_url(media[:url].to_s))
            candidates << normalize_story_id_token(story_id_hint_from_media_url(media[:video_url].to_s))
            candidates << normalize_story_id_token(story_id_hint_from_media_url(media[:image_url].to_s))
          end

          candidates.find(&:present?).to_s
        rescue StandardError
          ""
        end

        def resolve_story_assignment_context(context_username:, story_id:, canonical_story_url:, live_story_url:, media_owner_username:)
          sid = normalize_story_id_token(story_id.to_s)
          return { ok: false, reason_code: "story_id_unresolved", story_id: sid, username: "" } if sid.blank?

          context_user = normalize_username(context_username)
          live_identity = story_url_identity(live_story_url.to_s)
          live_user = normalize_username(live_identity[:username].to_s)
          live_story_id = normalize_story_id_token(live_identity[:story_id].to_s)
          owner_user = normalize_username(media_owner_username)

          chosen_username = live_user.presence || context_user.presence || owner_user.presence
          return { ok: false, reason_code: "story_username_unresolved", story_id: sid, username: "" } if chosen_username.blank?

          if live_story_id.present? && live_story_id != sid
            return {
              ok: false,
              reason_code: "story_id_live_url_conflict",
              story_id: sid,
              username: chosen_username,
              conflict: true
            }
          end

          if owner_user.present? && owner_user != chosen_username
            return {
              ok: false,
              reason_code: "story_owner_username_conflict",
              story_id: sid,
              username: chosen_username,
              conflict: true
            }
          end

          final_story_url = canonical_story_url(
            username: chosen_username,
            story_id: sid,
            fallback_url: live_story_url.to_s.presence || canonical_story_url.to_s
          )

          {
            ok: true,
            story_id: sid,
            username: chosen_username,
            story_url: final_story_url,
            story_ref: "#{chosen_username}:#{sid}",
            conflict: false,
            reconciled_from_live_url: context_user.present? && live_user.present? && context_user != live_user
          }
        rescue StandardError
          {
            ok: false,
            reason_code: "story_assignment_exception",
            story_id: normalize_story_id_token(story_id.to_s),
            username: normalize_username(context_username),
            conflict: true
          }
        end

        def story_live_context_matches_assignment?(live_story_url:, story_username:, story_id:)
          expected_username = normalize_username(story_username.to_s)
          expected_story_id = normalize_story_id_token(story_id.to_s)
          return false if expected_username.blank?

          live_identity = story_url_identity(live_story_url.to_s)
          live_username = normalize_username(live_identity[:username].to_s)
          return false if live_username.blank?
          return false if live_username != expected_username

          live_story_id = normalize_story_id_token(live_identity[:story_id].to_s)
          return false if live_story_id.present? && expected_story_id.present? && live_story_id != expected_story_id

          true
        rescue StandardError
          false
        end

        def stamp_story_assignment_validation!(downloaded_event:, profile:, story_id:, story_url:, story_username:, media:, cache:, driver:)
          return unless downloaded_event

          normalized_story_id = normalize_story_id_token(story_id.to_s)
          profile_username = normalize_username(profile&.username.to_s)
          requested_username = normalize_username(story_username.to_s)
          story_identity = story_url_identity(story_url.to_s)
          url_username = normalize_username(story_identity[:username].to_s)
          url_story_id = normalize_story_id_token(story_identity[:story_id].to_s)
          owner_username = normalize_username(media.is_a?(Hash) ? media[:owner_username].to_s : "")

          validation = {
            checked_at: Time.current.utc.iso8601(3),
            profile_username: profile_username,
            story_username: requested_username,
            story_url_username: url_username.presence,
            story_id: normalized_story_id,
            story_url_story_id: url_story_id.presence,
            media_owner_username: owner_username.presence,
            media_source: media.is_a?(Hash) ? media[:source].to_s.presence : nil,
            status: "passed",
            reason_code: nil,
            api_story_found: nil
          }

          if normalized_story_id.blank?
            validation[:status] = "failed"
            validation[:reason_code] = "missing_numeric_story_id"
          elsif profile_username.blank?
            validation[:status] = "failed"
            validation[:reason_code] = "missing_profile_username"
          elsif url_username.present? && url_username != profile_username
            validation[:status] = "failed"
            validation[:reason_code] = "story_url_username_mismatch"
          elsif url_story_id.present? && url_story_id != normalized_story_id
            validation[:status] = "failed"
            validation[:reason_code] = "story_url_story_id_mismatch"
          elsif owner_username.present? && owner_username != profile_username
            validation[:status] = "failed"
            validation[:reason_code] = "media_owner_username_mismatch"
          else
            api_story = resolve_story_item_via_api(
              username: profile_username,
              story_id: normalized_story_id,
              cache: cache,
              driver: driver
            )
            validation[:api_story_found] = api_story.is_a?(Hash)
            if api_story.is_a?(Hash)
              api_owner = normalize_username(api_story[:owner_username].to_s)
              validation[:api_owner_username] = api_owner.presence
              if api_owner.present? && api_owner != profile_username
                validation[:status] = "failed"
                validation[:reason_code] = "api_owner_username_mismatch"
              end
            else
              validation[:status] = "unknown"
              validation[:reason_code] = "api_story_not_resolved"
            end
          end

          metadata = downloaded_event.metadata.is_a?(Hash) ? downloaded_event.metadata.deep_dup : {}
          metadata["assignment_validation"] = validation
          downloaded_event.update!(metadata: metadata)

          return unless validation[:status] == "failed"

          profile.record_event!(
            kind: "story_assignment_validation_failed",
            external_id: "story_assignment_validation_failed:#{normalized_story_id}:#{Time.current.utc.iso8601(6)}",
            occurred_at: Time.current,
            metadata: {
              source: "home_story_carousel",
              story_id: normalized_story_id,
              story_url: story_url.to_s,
              archive_event_id: downloaded_event.id,
              archive_event_external_id: downloaded_event.external_id.to_s,
              validation: validation
            }
          )
        rescue StandardError
          nil
        end

        def story_media_resolution_metadata(media_probe)
          payload = media_probe.is_a?(Hash) ? media_probe : {}
          attempts = Array(payload[:attempts]).select { |row| row.is_a?(Hash) }
          api_failure = payload[:api_failure].is_a?(Hash) ? payload[:api_failure] : {}

          meta = {
            media_resolution_attempts: attempts.length,
            media_resolution_sources: attempts.map { |row| row[:source].to_s.presence }.compact.uniq,
            media_resolution_recovered: payload.dig(:media, :url).to_s.present?,
            api_rate_limited: ActiveModel::Type::Boolean.new.cast(payload[:api_rate_limited]),
            api_failure_status: api_failure[:status].to_i.positive? ? api_failure[:status].to_i : nil,
            api_failure_endpoint: api_failure[:endpoint].to_s.presence,
            api_failure_reason: api_failure[:reason].to_s.presence,
            api_useragent_mismatch: ActiveModel::Type::Boolean.new.cast(api_failure[:useragent_mismatch]),
            api_failure_response_snippet: api_failure[:response_snippet].to_s.presence&.byteslice(0, 220),
            media_resolution_error_class: payload[:media_resolution_error_class].to_s.presence,
            media_resolution_error_message: payload[:media_resolution_error_message].to_s.presence
          }

          occurred_at_epoch = api_failure[:occurred_at_epoch].to_i
          if occurred_at_epoch.positive?
            meta[:api_failure_at] = Time.at(occurred_at_epoch).utc.iso8601
          end
          meta.compact
        rescue StandardError
          {}
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
          extra_meta = extra.compact
          payload = {
            source: "home_story_carousel",
            reason: reason.to_s,
            failure_category: classify_story_sync_failure(error: error, reason: reason, extra: extra_meta),
            retryable: retryable_story_sync_failure?(error: error, reason: reason, extra: extra_meta),
            story_id: story_id.to_s,
            story_ref: story_ref.to_s,
            story_url: story_url.to_s,
            media_url: media_url.to_s.presence,
            error_class: error&.class&.name,
            error_message: error&.message.to_s&.byteslice(0, 500)
          }.compact
          payload.merge!(extra_meta)
          payload
        end

        def classify_story_sync_failure(error:, reason: nil, extra: {})
          message = error&.message.to_s&.downcase.to_s
          normalized_reason = reason.to_s.downcase
          api_status = extra[:api_failure_status].to_i
          api_rate_limited = ActiveModel::Type::Boolean.new.cast(extra[:api_rate_limited])

          return "network" if transient_story_sync_failure?(error)
          return "throttled" if api_rate_limited || api_status == 429
          return "session" if message.include?("login") || message.include?("cookie") || message.include?("csrf")
          return "navigation" if normalized_reason.include?("next_navigation_failed") || normalized_reason.include?("duplicate_story_key")
          return "parsing" if normalized_reason.include?("story_id_unresolved") || normalized_reason.include?("context_missing")
          return "assignment" if normalized_reason.include?("story_assignment")
          return "assignment" if normalized_reason.include?("story_url_username_mismatch")
          return "assignment" if normalized_reason.include?("story_owner_username_conflict")
          return "assignment" if normalized_reason.include?("story_id_username_conflict_in_run")
          return "assignment" if normalized_reason.include?("story_id_live_url_conflict")
          return "navigation" if normalized_reason.include?("story_live_context_unstable")
          return "navigation" if normalized_reason.include?("story_page_unavailable")
          return "navigation" if normalized_reason.include?("story_view_gate")
          return "storage" if message.include?("attach_failed") || message.include?("active storage")
          return "media_fetch" if normalized_reason.include?("api_story_media_unavailable")
          return "media_fetch" if message.include?("media") || message.include?("invalid media url") || message.include?("http")
          return "media_fetch" if normalized_reason.include?("media")

          "unknown"
        end

        def retryable_story_sync_failure?(error:, reason:, extra: {})
          return true if transient_story_sync_failure?(error)

          normalized_reason = reason.to_s.downcase
          api_status = extra[:api_failure_status].to_i
          api_rate_limited = ActiveModel::Type::Boolean.new.cast(extra[:api_rate_limited])
          return true if api_rate_limited || [ 429, 502, 503, 504 ].include?(api_status)

          return true if normalized_reason.include?("api_story_media_unavailable")
          return true if normalized_reason.include?("story_id_unresolved")
          return true if normalized_reason.include?("next_navigation_failed")
          return true if normalized_reason.include?("loop_exited_without_story_processing")
          return true if normalized_reason.include?("story_page_unavailable")
          return true if normalized_reason.include?("story_live_context_unstable")
          return true if normalized_reason.include?("story_view_gate")

          false
        end

        def transient_story_sync_failure?(error)
          return false unless error

          return true if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
          return true if error.is_a?(Errno::ECONNRESET) || error.is_a?(Errno::ECONNREFUSED)
          return true if defined?(Timeout::Error) && error.is_a?(Timeout::Error)

          msg = error.message.to_s.downcase
          msg.include?("timeout") || msg.include?("http 429") || msg.include?("http 502") || msg.include?("http 503") || msg.include?("http 504")
        end

        def enqueue_story_reply_delivery!(profile:, story_id:, comment_text:, downloaded_event:, metadata:)
          sid = story_id.to_s.strip
          text = comment_text.to_s.strip
          return { queued: false, reason: "missing_story_id" } if sid.blank?
          return { queued: false, reason: "blank_comment" } if text.blank?

          if profile.instagram_profile_events.where(kind: "story_reply_sent", external_id: "story_reply_sent:#{sid}").exists?
            return { queued: false, reason: "already_sent" }
          end

          existing_queue_event = profile.instagram_profile_events.find_by(kind: "story_reply_queued", external_id: "story_reply_queued:#{sid}")
          if existing_queue_event
            metadata = existing_queue_event.metadata.is_a?(Hash) ? existing_queue_event.metadata : {}
            status = metadata["delivery_status"].to_s
            queue_fresh = existing_queue_event.detected_at.present? && existing_queue_event.detected_at > 12.hours.ago
            if !%w[sent failed].include?(status) && queue_fresh
              return { queued: false, reason: "already_queued" }
            end
          end

          queue_event = profile.record_event!(
            kind: "story_reply_queued",
            external_id: "story_reply_queued:#{sid}",
            occurred_at: Time.current,
            metadata: metadata.merge(
              comment_text: text,
              auto_reply: true,
              delivery_status: "queued",
              queued_at: Time.current.iso8601(3)
            )
          )

          job = SendStoryReplyJob.perform_later(
            instagram_account_id: @account.id,
            instagram_profile_id: profile.id,
            story_id: sid,
            reply_text: text,
            story_metadata: metadata,
            downloaded_event_id: downloaded_event&.id,
            validation_requested_at: metadata["eligibility_validation_requested_at"] || metadata[:eligibility_validation_requested_at]
          )
          queue_event.update!(
            metadata: queue_event.metadata.merge(
              "active_job_id" => job.job_id,
              "queue_name" => job.queue_name
            )
          )

          {
            queued: true,
            job_id: job.job_id,
            queue_name: job.queue_name
          }
        rescue StandardError => e
          {
            queued: false,
            reason: "reply_enqueue_failed",
            error_class: e.class.name,
            error_message: e.message.to_s
          }
        end

        def attach_media_to_event(event, bytes:, filename:, content_type:)
          return false unless event
          return true if event.media.attached?

          event.media.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
          event.media.attached?
        rescue StandardError => e
          Rails.logger.warn("[HomeCarouselSync] direct media attach failed event_id=#{event&.id}: #{e.class}: #{e.message}")
          false
        end

        def attach_download_to_event(event:, download:)
          return false unless event
          return true if event.media.attached?

          blob = download.is_a?(Hash) ? download[:blob] : nil
          if blob.present?
            event.media.attach(blob)
            return event.media.attached?
          end

          attach_media_to_event(
            event,
            bytes: download[:bytes],
            filename: download[:filename],
            content_type: download[:content_type]
          )
        rescue StandardError => e
          Rails.logger.warn("[HomeCarouselSync] media attach from download failed event_id=#{event&.id}: #{e.class}: #{e.message}")
          false
        end

        def archive_link_metadata(downloaded_event:)
          return {} if downloaded_event.blank?

          {
            archive_event_id: downloaded_event.id,
            archive_event_external_id: downloaded_event.external_id.to_s
          }
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
