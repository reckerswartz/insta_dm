module InstagramAccounts
  class StoryReplyResendService
    Result = Struct.new(:payload, :status, keyword_init: true)

    def initialize(account:, event_id:, comment_text:, instagram_client: nil)
      @account = account
      @event_id = event_id
      @comment_text = comment_text.to_s
      @instagram_client = instagram_client
    end

    def call
      event = find_accessible_event
      return not_found_result unless event

      profile = event.instagram_profile
      return Result.new(payload: { error: "Profile is missing for this story event" }, status: :unprocessable_entity) if profile.blank?

      message_text = resolved_message_text(event: event)
      return Result.new(payload: { error: "No saved comment text is available for resend" }, status: :unprocessable_entity) if message_text.blank?

      story_id = story_id_for(event: event)
      return Result.new(payload: { error: "Story id is missing for this event" }, status: :unprocessable_entity) if story_id.blank?

      username = profile.username.to_s.strip
      return Result.new(payload: { error: "Profile username is unavailable for story reply" }, status: :unprocessable_entity) if username.blank?

      update_manual_send_state!(
        event: event,
        status: "sending",
        comment_text: message_text,
        reason: "manual_send_requested",
        message: "Sending comment..."
      )
      broadcast_status!(
        event: event,
        story_id: story_id,
        status: "sending",
        message: "Sending comment...",
        reason: "manual_send_requested"
      )

      eligibility = verify_story_reply_eligibility(profile: profile, story_id: story_id, comment_text: message_text)

      unless eligibility[:eligible]
        return ineligible_result(
          event: event,
          profile: profile,
          story_id: story_id,
          message_text: message_text,
          eligibility: eligibility
        )
      end

      response = instagram_client.send_story_reply_via_api!(
        story_id: story_id,
        story_username: username,
        comment_text: message_text
      )
      unless ActiveModel::Type::Boolean.new.cast(response[:posted])
        return send_failure_result(
          event: event,
          profile: profile,
          story_id: story_id,
          message_text: message_text,
          reason: response[:reason].to_s.presence || "api_send_failed",
          api_response: response
        )
      end

      message = account.instagram_messages.create!(
        instagram_profile: profile,
        direction: "outgoing",
        body: message_text,
        status: "sent",
        sent_at: Time.current
      )

      profile.record_event!(
        kind: "story_reply_resent",
        external_id: "story_reply_resent:#{story_id}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: story_metadata(event: event).merge(
          resent_comment_text: message_text,
          instagram_message_id: message.id,
          api_method: response[:method].to_s.presence || "api",
          api_thread_id: response[:api_thread_id].to_s.presence,
          api_item_id: response[:api_item_id].to_s.presence
        )
      )

      update_manual_send_state!(
        event: event,
        status: "sent",
        comment_text: message_text,
        reason: "comment_posted",
        message: "Comment sent successfully."
      )
      broadcast_status!(
        event: event,
        story_id: story_id,
        status: "sent",
        message: "Comment sent successfully.",
        reason: "comment_posted"
      )

      Result.new(
        payload: {
          success: true,
          status: "sent",
          message: "Comment sent successfully.",
          reason: "comment_posted",
          event_id: event.id,
          story_id: story_id,
          instagram_message_id: message.id,
          api_thread_id: response[:api_thread_id].to_s.presence,
          api_item_id: response[:api_item_id].to_s.presence
        },
        status: :ok
      )
    rescue StandardError => e
      if event.present?
        mark_failed!(
          event: event,
          story_id: story_id_for(event: event),
          error_message: e.message.to_s,
          error_class: e.class.name,
          reason: "service_exception"
        )
      end
      Result.new(payload: { status: "failed", error: e.message.to_s, message: "Comment sending failed.", reason: "service_exception" }, status: :unprocessable_entity)
    end

    private

    attr_reader :account, :event_id, :comment_text

    def find_accessible_event
      event = InstagramProfileEvent.includes(:instagram_profile).find_by(id: event_id)
      return nil unless accessible_event?(event)

      event
    end

    def accessible_event?(event)
      event.story_archive_item? && event.instagram_profile&.instagram_account_id == account.id
    end

    def not_found_result
      Result.new(payload: { status: "failed", error: "Event not found or not accessible", message: "Story event is unavailable." }, status: :not_found)
    end

    def resolved_message_text(event:)
      candidate = comment_text.strip
      return candidate if candidate.present?

      meta = story_metadata(event: event)
      saved = meta["reply_comment"].to_s.strip
      return saved if saved.present?

      event.llm_generated_comment.to_s.strip
    end

    def story_id_for(event:)
      story_metadata(event: event)["story_id"].to_s.strip
    end

    def story_metadata(event:)
      event.metadata.is_a?(Hash) ? event.metadata : {}
    end

    def verify_story_reply_eligibility(profile:, story_id:, comment_text:)
      eligibility = instagram_client.story_reply_eligibility(
        username: profile.username.to_s,
        story_id: story_id
      )
      eligibility = {} unless eligibility.is_a?(Hash)
      return eligibility if eligibility[:eligible] != true

      if already_posted?(profile: profile, story_id: story_id, comment_text: comment_text)
        return {
          eligible: false,
          status: "sent",
          reason_code: "already_posted"
        }
      end

      {
        eligible: true,
        status: "eligible",
        reason_code: nil
      }
    end

    def already_posted?(profile:, story_id:, comment_text:)
      normalized = normalize_comment(comment_text)
      return false if normalized.blank?

      recent = profile.instagram_profile_events
        .where(kind: %w[story_reply_sent story_reply_resent])
        .order(id: :desc)
        .limit(40)

      recent.any? do |row|
        next false unless story_id_from_reply_event(row) == story_id.to_s

        replied_comment = extract_reply_comment(row)
        replied_comment = comment_text if replied_comment.blank?
        normalize_comment(replied_comment) == normalized
      end
    rescue StandardError
      false
    end

    def ineligible_result(event:, profile:, story_id:, message_text:, eligibility:)
      reason = eligibility[:reason_code].to_s.presence || "ineligible"
      status = eligibility[:status].to_s

      if status == "sent" && reason == "already_posted"
        update_manual_send_state!(
          event: event,
          status: "sent",
          comment_text: message_text,
          reason: reason,
          message: "Comment already posted."
        )
        broadcast_status!(
          event: event,
          story_id: story_id,
          status: "sent",
          reason: reason,
          message: "Comment already posted."
        )
        return Result.new(
          payload: {
            success: true,
            status: "sent",
            message: "Comment already posted.",
            reason: reason,
            event_id: event.id,
            story_id: story_id,
            already_posted: true
          },
          status: :ok
        )
      end

      if status == "expired_removed"
        update_manual_send_state!(
          event: event,
          status: "expired_removed",
          comment_text: message_text,
          reason: reason,
          message: "Story expired or removed."
        )
        profile.record_event!(
          kind: "story_reply_resend_unavailable",
          external_id: "story_reply_resend_unavailable:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: story_metadata(event: event).merge(
            resend_reason_code: reason,
            resend_error_message: "Story unavailable"
          )
        )
        broadcast_status!(
          event: event,
          story_id: story_id,
          status: "expired_removed",
          reason: reason,
          message: "Story expired or removed."
        )
        return Result.new(
          payload: {
            success: false,
            status: "expired_removed",
            message: "Story expired or removed.",
            reason: reason,
            event_id: event.id,
            story_id: story_id,
            error: "Story expired or removed"
          },
          status: :unprocessable_entity
        )
      end

      mark_failed!(
        event: event,
        story_id: story_id,
        error_message: "Story not eligible for manual comment",
        error_class: "EligibilityError",
        reason: reason,
        profile: profile,
        message_text: message_text
      )
      Result.new(
        payload: {
          success: false,
          status: "failed",
          message: "Story is not eligible for commenting.",
          event_id: event.id,
          story_id: story_id,
          error: "Story is not eligible for commenting",
          reason: reason
        },
        status: :unprocessable_entity
      )
    end

    def send_failure_result(event:, profile:, story_id:, message_text:, reason:, api_response:)
      if reason_indicates_story_expired?(reason)
        update_manual_send_state!(
          event: event,
          status: "expired_removed",
          comment_text: message_text,
          reason: reason,
          message: "Story expired or removed."
        )
        broadcast_status!(
          event: event,
          story_id: story_id,
          status: "expired_removed",
          reason: reason,
          message: "Story expired or removed."
        )
        profile.record_event!(
          kind: "story_reply_resend_unavailable",
          external_id: "story_reply_resend_unavailable:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: story_metadata(event: event).merge(
            resend_reason_code: reason,
            resend_error_message: "Story unavailable",
            resend_api_response: api_response
          )
        )

        return Result.new(
          payload: {
            success: false,
            status: "expired_removed",
            message: "Story expired or removed.",
            reason: reason,
            event_id: event.id,
            story_id: story_id,
            error: "Story expired or removed"
          },
          status: :unprocessable_entity
        )
      end

      mark_failed!(
        event: event,
        story_id: story_id,
        error_message: "Story comment API failed: #{reason}",
        error_class: "StoryReplyApiError",
        reason: reason,
        profile: profile,
        message_text: message_text,
        api_response: api_response
      )
      Result.new(
        payload: {
          success: false,
          status: "failed",
          message: "Comment sending failed.",
          event_id: event.id,
          story_id: story_id,
          error: "Comment sending failed",
          reason: reason
        },
        status: :unprocessable_entity
      )
    end

    def mark_failed!(event:, story_id:, error_message:, error_class:, reason:, profile: nil, message_text: nil, api_response: nil)
      prof = profile || event.instagram_profile
      text = message_text.presence || resolved_message_text(event: event)
      update_manual_send_state!(
        event: event,
        status: "failed",
        comment_text: text,
        reason: reason,
        error_message: error_message,
        message: "Comment sending failed."
      )

      if text.present?
        account.instagram_messages.create!(
          instagram_profile: prof,
          direction: "outgoing",
          body: text,
          status: "failed",
          error_message: error_message.to_s
        )
      end

      prof.record_event!(
        kind: "story_reply_resend_failed",
        external_id: "story_reply_resend_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: story_metadata(event: event).merge(
          resend_reason_code: reason,
          resend_error_class: error_class.to_s,
          resend_error_message: error_message.to_s,
          resend_api_response: api_response
        )
      )

      broadcast_status!(
        event: event,
        story_id: story_id,
        status: "failed",
        reason: reason,
        message: "Comment sending failed.",
        error: error_message
      )
    rescue StandardError
      nil
    end

    def update_manual_send_state!(event:, status:, comment_text:, reason:, message:, error_message: nil)
      event.with_lock do
        event.reload
        metadata = story_metadata(event: event).deep_dup
        now = Time.current.utc.iso8601(3)
        metadata["manual_send_status"] = status.to_s
        metadata["manual_send_last_comment"] = comment_text.to_s
        metadata["manual_send_reason"] = reason.to_s.presence
        metadata["manual_send_message"] = message.to_s.presence
        metadata["manual_send_updated_at"] = now
        metadata["manual_send_attempt_count"] = metadata["manual_send_attempt_count"].to_i + 1 if status.to_s == "sending"

        if status.to_s == "sending"
          metadata["manual_send_last_attempted_at"] = now
        elsif status.to_s == "sent"
          metadata["reply_comment"] = comment_text.to_s
          metadata["manual_send_last_sent_at"] = now
          metadata["manual_resend_last_at"] = now
        end

        if status.to_s == "failed"
          metadata["manual_send_last_error"] = error_message.to_s
        else
          metadata.delete("manual_send_last_error")
        end

        review = quality_review_snapshot(event: event, comment_text: comment_text, status: status, reason: reason)
        metadata["manual_send_quality_review"] = review if review.present?

        event.update!(metadata: metadata)
      end
    rescue StandardError
      nil
    end

    def broadcast_status!(event:, story_id:, status:, message:, reason:, error: nil)
      return unless event.present?

      ActionCable.server.broadcast(
        "story_reply_status_#{account.id}",
        {
          event_id: event.id,
          story_id: story_id.to_s,
          status: status.to_s,
          reason: reason.to_s.presence,
          message: message.to_s.presence,
          error: error.to_s.presence,
          updated_at: Time.current.utc.iso8601(3)
        }.compact
      )
    rescue StandardError
      nil
    end

    def story_id_from_reply_event(row)
      metadata = row.metadata.is_a?(Hash) ? row.metadata : {}
      story_id = metadata["story_id"].to_s.strip
      return story_id if story_id.present?

      external_id = row.external_id.to_s
      return Regexp.last_match(1).to_s if external_id.match?(/\Astory_reply_sent:([^:]+)\z/)
      return Regexp.last_match(1).to_s if external_id.match?(/\Astory_reply_resent:([^:]+):/)

      ""
    rescue StandardError
      ""
    end

    def extract_reply_comment(row)
      metadata = row.metadata.is_a?(Hash) ? row.metadata : {}
      metadata["resent_comment_text"].to_s.presence ||
        metadata["reply_comment"].to_s.presence ||
        metadata["llm_generated_comment"].to_s.presence
    rescue StandardError
      nil
    end

    def normalize_comment(text)
      text.to_s.downcase.gsub(/\s+/, " ").strip
    end

    def reason_indicates_story_expired?(reason)
      value = reason.to_s.downcase
      return true if value.include?("story_unavailable")
      return true if value.include?("story_not_found")
      return true if value.include?("api_story_not_found")
      return true if value.include?("missing_story")
      return true if value.include?("expired_story")
      return true if value.include?("content_unavailable")

      false
    end

    def quality_review_snapshot(event:, comment_text:, status:, reason:)
      selected_comment = comment_text.to_s.strip
      return {} if selected_comment.blank?

      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      ranked = Array(llm_meta["ranked_candidates"]).select { |row| row.is_a?(Hash) }
      normalized_selected = normalize_comment(selected_comment)
      selected_rank = ranked.find_index { |row| normalize_comment(row["comment"]) == normalized_selected }
      selected_score = ranked[selected_rank]["score"] if selected_rank

      generated_comment = event.llm_generated_comment.to_s.strip
      generated_present = generated_comment.present?
      generated_mismatch = generated_present && normalize_comment(generated_comment) != normalized_selected
      selected_missing_from_ranked = selected_rank.nil? && ranked.any?

      breakdown = llm_meta["selected_relevance_breakdown"].is_a?(Hash) ? llm_meta["selected_relevance_breakdown"] : {}
      visual_signal = breakdown.dig("visual_context", "label").to_s.presence
      context_signal = breakdown.dig("user_context_match", "label").to_s.presence
      engagement_signal = breakdown.dig("engagement_relevance", "label").to_s.presence

      story_meta = story_metadata(event: event)
      validated_insights = story_meta.dig("validated_story_insights")
      object_labels = Array(validated_insights.is_a?(Hash) ? validated_insights["objects"] : []).map(&:to_s).reject(&:blank?).first(10)
      detected_usernames = Array(validated_insights.is_a?(Hash) ? validated_insights["detected_usernames"] : []).map(&:to_s).reject(&:blank?).first(10)

      {
        reviewed_at: Time.current.utc.iso8601(3),
        status: status.to_s,
        reason: reason.to_s.presence,
        selected_comment: selected_comment,
        selected_comment_rank: (selected_rank.nil? ? nil : selected_rank + 1),
        selected_comment_score: selected_score,
        selected_comment_in_ranked_candidates: !selected_rank.nil?,
        generated_comment_present: generated_present,
        generated_comment_mismatch: generated_mismatch,
        selected_comment_missing_from_ranked: selected_missing_from_ranked,
        visual_context_signal: visual_signal,
        user_context_signal: context_signal,
        engagement_signal: engagement_signal,
        detected_objects: object_labels,
        detected_usernames: detected_usernames,
        tuning_hint: review_tuning_hint(
          generated_mismatch: generated_mismatch,
          selected_missing_from_ranked: selected_missing_from_ranked,
          visual_signal: visual_signal,
          context_signal: context_signal
        )
      }.compact
    rescue StandardError
      {}
    end

    def review_tuning_hint(generated_mismatch:, selected_missing_from_ranked:, visual_signal:, context_signal:)
      if selected_missing_from_ranked
        return "selected_comment_not_ranked_candidate"
      end
      if generated_mismatch
        return "manual_override_differs_from_generated"
      end
      if %w[low unknown].include?(visual_signal.to_s.downcase)
        return "visual_context_signal_weak"
      end
      if %w[low unknown].include?(context_signal.to_s.downcase)
        return "user_context_signal_weak"
      end

      "aligned"
    rescue StandardError
      "unknown"
    end

    def instagram_client
      @instagram_client ||= Instagram::Client.new(account: account)
    end
  end
end
