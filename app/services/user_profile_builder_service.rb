class UserProfileBuilderService
  def refresh!(profile:)
    stories = profile.instagram_stories.processed.to_a
    return nil if stories.empty?

    by_hour = Hash.new(0)
    by_weekday = Hash.new(0)
    location_counts = Hash.new(0)
    content_signal_counts = Hash.new(0)
    topic_counts = Hash.new(0)
    hashtag_counts = Hash.new(0)
    sentiment_counts = Hash.new(0)

    stories.each do |story|
      timestamp = story.taken_at || story.created_at
      by_hour[timestamp.hour] += 1
      by_weekday[timestamp.wday] += 1

      metadata = story.metadata.is_a?(Hash) ? story.metadata : {}
      Array(metadata["location_tags"]).each { |tag| location_counts[tag.to_s] += 1 if tag.present? }
      Array(metadata["content_signals"]).each { |signal| content_signal_counts[signal.to_s] += 1 if signal.present? }
      understanding = metadata["content_understanding"].is_a?(Hash) ? metadata["content_understanding"] : {}
      Array(understanding["topics"]).each { |topic| topic_counts[topic.to_s] += 1 if topic.present? }
      Array(understanding["hashtags"]).each { |tag| hashtag_counts[tag.to_s] += 1 if tag.present? }
      sentiment = understanding["sentiment"].to_s.strip
      sentiment_counts[sentiment] += 1 if sentiment.present?
    end

    story_person_counts = InstagramStoryFace.joins(:instagram_story)
      .where(instagram_stories: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .group(:instagram_story_person_id)
      .count

    post_person_counts = InstagramPostFace.joins(:instagram_profile_post)
      .where(instagram_profile_posts: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .group(:instagram_story_person_id)
      .count

    person_counts = story_person_counts.merge(post_person_counts) { |_person_id, left, right| left.to_i + right.to_i }

    top_people = profile.instagram_story_people.where(id: person_counts.keys).map do |person|
      {
        person_id: person.id,
        role: person.role,
        label: person.label.to_s.presence,
        appearances: person_counts[person.id].to_i
      }.compact
    end.sort_by { |row| -row[:appearances] }.first(10)

    score = activity_score(
      stories_count: stories.length,
      active_hours_count: by_hour.keys.length,
      secondary_person_mentions: top_people.reject { |row| row[:role] == "primary_user" }.sum { |row| row[:appearances].to_i }
    )

    record = InstagramProfileBehaviorProfile.find_or_initialize_by(instagram_profile: profile)
    existing_summary = record.behavioral_summary.is_a?(Hash) ? record.behavioral_summary.deep_dup : {}
    existing_metadata = record.metadata.is_a?(Hash) ? record.metadata.deep_dup : {}

    summary = {
      posting_time_pattern: {
        hour_histogram: by_hour.sort.to_h,
        weekday_histogram: by_weekday.sort.to_h
      },
      common_locations: sort_top(location_counts),
      frequent_secondary_persons: top_people.reject { |row| row[:role] == "primary_user" },
      content_categories: sort_top(content_signal_counts),
      topic_clusters: sort_top(topic_counts),
      top_hashtags: sort_top(hashtag_counts),
      sentiment_trend: sort_top(sentiment_counts, limit: 5)
    }
    summary["face_identity_profile"] = existing_summary["face_identity_profile"] if existing_summary["face_identity_profile"].is_a?(Hash)
    summary["related_individuals"] = Array(existing_summary["related_individuals"]) if existing_summary["related_individuals"].present?
    summary["known_username_matches"] = Array(existing_summary["known_username_matches"]) if existing_summary["known_username_matches"].present?

    record.activity_score = score
    record.behavioral_summary = summary
    record.metadata = existing_metadata.merge(
      stories_processed: stories.length,
      post_faces_processed: profile.instagram_post_faces.count,
      refreshed_at: Time.current.iso8601
    )
    record.save!
    record
  end

  private

  def sort_top(count_hash, limit: 20)
    count_hash.sort_by { |_key, count| -count }.first(limit).to_h
  end

  def activity_score(stories_count:, active_hours_count:, secondary_person_mentions:)
    volume = [ stories_count.to_f / 30.0, 1.0 ].min
    hourly_diversity = [ active_hours_count.to_f / 24.0, 1.0 ].min
    social = [ secondary_person_mentions.to_f / 20.0, 1.0 ].min
    ((volume + hourly_diversity + social) / 3.0).round(4)
  end
end
