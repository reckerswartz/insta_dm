# frozen_string_literal: true

module Ai
  class PostEngagementSuitabilityClassifier
    HANDLE_REGEX = /@([a-z0-9._]{2,30})/i
    MIN_PERSONAL_SIGNAL_SCORE =
      ENV.fetch("POST_COMMENT_MIN_PERSONAL_SIGNAL_SCORE", "2").to_i.clamp(0, 6)
    BLOCKED_CONTENT_TYPES = %w[
      meme
      quote
      music_share
      religious_viral
      promotional
      generic_reshared
      reshared_content
    ].freeze
    PAGE_PROFILE_TAGS = %w[
      page
      business
      creator
      media
      news
      brand
      company
      meme
      aggregator
      fanpage
    ].freeze

    RESHARE_PATTERNS = [
      /\brepost\b/i,
      /\breshare\b/i,
      /\bshared\s+from\b/i,
      /\bshared\s+by\b/i,
      /\bcredit(?:s)?\b/i,
      /\boriginal\s+by\b/i,
      /\bvia\s+@?[a-z0-9._]+\b/i,
      /\bsource:\s*@?[a-z0-9._]+\b/i
    ].freeze

    QUOTE_PATTERNS = [
      /\bquote\b/i,
      /\bquotes\b/i,
      /\bmotivation(?:al)?\b/i,
      /\bthought\s+of\s+the\s+day\b/i,
      /\binspiration(?:al)?\b/i
    ].freeze

    MEME_PATTERNS = [
      /\bmeme(?:s)?\b/i,
      /\brelatable\b/i,
      /\bme\s+when\b/i,
      /\bwhen\s+you\b/i,
      /\bnobody:\b/i
    ].freeze

    MUSIC_PATTERNS = [
      /\bspotify\b/i,
      /\bnow\s+playing\b/i,
      /\bsong\s+of\s+the\s+day\b/i,
      /\blyrics?\b/i,
      /\bplaylist\b/i,
      /\baudio\b/i
    ].freeze

    RELIGIOUS_VIRAL_PATTERNS = [
      /\bamen\b/i,
      /\bshare\s+if\s+you\b/i,
      /\bviral\b/i,
      /\btrending\b/i,
      /\bblessing(?:s)?\b/i,
      /\bjai\s+shree\s+ram\b/i,
      /\ballah\b/i,
      /\bgod\s+is\s+great\b/i
    ].freeze

    PROMOTIONAL_PATTERNS = [
      /\bshop\s+now\b/i,
      /\blink\s+in\s+bio\b/i,
      /\bdiscount\b/i,
      /\boffer\b/i,
      /\bpromo\b/i,
      /\bsponsored\b/i,
      /\bad\b/i,
      /\bbuy\s+now\b/i
    ].freeze

    FIRST_PERSON_PATTERNS = [
      /\bmy\b/i,
      /\bme\b/i,
      /\bour\b/i,
      /\bi\b/i,
      /\bwe\b/i,
      /\bus\b/i
    ].freeze

    LIFE_EVENT_PATTERNS = [
      /\btoday\b/i,
      /\byesterday\b/i,
      /\bfamily\b/i,
      /\bfriends\b/i,
      /\bbirthday\b/i,
      /\banniversary\b/i,
      /\btrip\b/i,
      /\bvacation\b/i
    ].freeze
    VIRAL_HASHTAG_PATTERNS = [
      /#(?:fyp|explore|explorepage|trending|viral|reels|reelitfeelit|insta|instagood|follow|likeforlike)\b/i
    ].freeze
    PAGE_STYLE_PATTERNS = [
      /\bone\s+word\s+for\b/i,
      /\bspotted\b/i,
      /\bairport\s+look\b/i,
      /\bpap(?:s|arazzi)?\b/i,
      /\bcaption\s+this\b/i,
      /\bwhich\s+look\b/i
    ].freeze

    def initialize(profile:, post:, analysis:, metadata:)
      @profile = profile
      @post = post
      @analysis = analysis.is_a?(Hash) ? analysis : {}
      @metadata = metadata.is_a?(Hash) ? metadata : {}
    end

    def classify
      profile_username = normalize_username(@profile&.username)
      profile_tags = profile_tag_names
      page_profile = (profile_tags & PAGE_PROFILE_TAGS).any?
      caption_text = @post&.caption.to_s
      hashtags = normalized_strings(@analysis["hashtags"])
      mentions = normalized_strings(@analysis["mentions"])
      corpus = textual_corpus(caption_text: caption_text, hashtags: hashtags, mentions: mentions)
      reshare_hits = detect_patterns(text: corpus, patterns: RESHARE_PATTERNS)
      quote_hits = detect_patterns(text: corpus, patterns: QUOTE_PATTERNS)
      meme_hits = detect_patterns(text: corpus, patterns: MEME_PATTERNS)
      music_hits = detect_patterns(text: corpus, patterns: MUSIC_PATTERNS)
      religious_viral_hits = detect_patterns(text: corpus, patterns: RELIGIOUS_VIRAL_PATTERNS)
      promotional_hits = detect_patterns(text: corpus, patterns: PROMOTIONAL_PATTERNS)
      first_person_hits = detect_patterns(text: corpus, patterns: FIRST_PERSON_PATTERNS)
      life_event_hits = detect_patterns(text: corpus, patterns: LIFE_EVENT_PATTERNS)
      viral_hashtag_hits = detect_patterns(text: hashtags.join(" "), patterns: VIRAL_HASHTAG_PATTERNS)
      page_style_hits = detect_patterns(text: corpus, patterns: PAGE_STYLE_PATTERNS)

      handles = detected_handles(corpus: corpus, mentions: mentions)
      external_handles = handles.reject { |value| value == profile_username }.first(12)
      repost = ActiveModel::Type::Boolean.new.cast(@metadata["is_repost"])
      source_owner_username = normalize_username(extract_source_owner_username)
      source_owner_mismatch = source_owner_username.present? && source_owner_username != profile_username

      face_count = @analysis.dig("face_summary", "face_count").to_i
      owner_faces_count = @analysis.dig("face_summary", "owner_faces_count").to_i

      personal_signal_score = 0
      personal_signal_score += 2 if owner_faces_count.positive?
      personal_signal_score += 1 if face_count.positive?
      personal_signal_score += 2 if first_person_hits.any?
      personal_signal_score += 1 if life_event_hits.any?
      personal_signal_score += 1 if caption_text.strip.length >= 40 && !page_profile && hashtags.length <= 6
      personal_signal_score += 1 if external_handles.empty? && hashtags.length <= 4 && mentions.length <= 2
      personal_signal_score -= 2 if repost || reshare_hits.any? || source_owner_mismatch
      personal_signal_score -= 1 if external_handles.any?
      personal_signal_score -= 1 if quote_hits.any? || meme_hits.any? || music_hits.any? || religious_viral_hits.any? || promotional_hits.any?
      personal_signal_score -= 1 if viral_hashtag_hits.any?
      personal_signal_score -= 1 if hashtags.length >= 7
      personal_signal_score -= 2 if page_profile && owner_faces_count.zero? && first_person_hits.empty?
      personal_signal_score -= 1 if page_style_hits.any? && owner_faces_count.zero?
      personal_signal_score = personal_signal_score.clamp(-6, 8)

      ownership =
        if repost || reshare_hits.any? || source_owner_mismatch
          "reshared"
        elsif external_handles.any? && owner_faces_count <= 0 && first_person_hits.empty?
          "uncertain"
        else
          "original"
        end

      content_type =
        if promotional_hits.any?
          "promotional"
        elsif music_hits.any?
          "music_share"
        elsif religious_viral_hits.any?
          "religious_viral"
        elsif meme_hits.any?
          "meme"
        elsif quote_hits.any?
          "quote"
        elsif ownership == "reshared"
          "reshared_content"
        elsif page_profile && personal_signal_score < (MIN_PERSONAL_SIGNAL_SCORE + 1)
          "generic_reshared"
        elsif external_handles.any? && personal_signal_score < MIN_PERSONAL_SIGNAL_SCORE
          "generic_reshared"
        elsif personal_signal_score >= MIN_PERSONAL_SIGNAL_SCORE
          "personal_post"
        else
          "generic_reshared"
        end

      reason_codes = []
      reason_codes << "metadata_repost_flag" if repost
      reason_codes << "source_owner_mismatch" if source_owner_mismatch
      reason_codes << "reshare_indicators_detected" if reshare_hits.any?
      reason_codes << "external_handles_detected" if external_handles.any?
      reason_codes << "quote_style_content" if quote_hits.any?
      reason_codes << "meme_style_content" if meme_hits.any?
      reason_codes << "music_share_content" if music_hits.any?
      reason_codes << "religious_or_viral_content" if religious_viral_hits.any?
      reason_codes << "promotional_content" if promotional_hits.any?
      reason_codes << "viral_hashtag_pattern" if viral_hashtag_hits.any?
      reason_codes << "high_hashtag_density" if hashtags.length >= 7
      reason_codes << "page_profile_context" if page_profile
      reason_codes << "page_style_editorial_content" if page_style_hits.any?
      reason_codes << "low_personal_signal" if personal_signal_score < MIN_PERSONAL_SIGNAL_SCORE
      reason_codes << "owner_faces_detected" if owner_faces_count.positive?
      reason_codes << "first_person_language_detected" if first_person_hits.any?
      reason_codes << "life_event_language_detected" if life_event_hits.any?
      reason_codes << "same_profile_owner_content" if ownership == "original"

      engagement_suitable =
        ownership == "original" &&
        !BLOCKED_CONTENT_TYPES.include?(content_type) &&
        personal_signal_score >= MIN_PERSONAL_SIGNAL_SCORE

      summary =
        if engagement_suitable
          "Original personal content cleared engagement thresholds."
        else
          "Skipped: #{content_type.humanize.downcase}, ownership #{ownership}, personal signal #{personal_signal_score}/#{MIN_PERSONAL_SIGNAL_SCORE}."
        end

      {
        "content_type" => content_type,
        "ownership" => ownership,
        "same_profile_owner_content" => ownership == "original",
        "engagement_suitable" => engagement_suitable,
        "reason_codes" => reason_codes.uniq.first(16),
        "detected_external_handles" => external_handles,
        "is_repost" => repost,
        "face_count" => face_count,
        "owner_faces_count" => owner_faces_count,
        "personal_signal_score" => personal_signal_score,
        "personal_signal_threshold" => MIN_PERSONAL_SIGNAL_SCORE,
        "source_owner_username" => source_owner_username.presence,
        "hashtag_count" => hashtags.length,
        "mention_count" => mentions.length,
        "profile_tags" => profile_tags.first(8),
        "summary" => summary
      }
    rescue StandardError => e
      {
        "content_type" => "unknown",
        "ownership" => "uncertain",
        "same_profile_owner_content" => false,
        "engagement_suitable" => false,
        "reason_codes" => [ "classifier_error" ],
        "detected_external_handles" => [],
        "is_repost" => false,
        "face_count" => 0,
        "owner_faces_count" => 0,
        "personal_signal_score" => -1,
        "personal_signal_threshold" => MIN_PERSONAL_SIGNAL_SCORE,
        "summary" => "Classifier error: #{e.class}"
      }
    end

    private

    def textual_corpus(caption_text:, hashtags:, mentions:)
      topics = normalized_strings(@analysis["topics"])
      objects = normalized_strings(@analysis["objects"])

      [
        caption_text.to_s,
        @analysis["image_description"].to_s,
        @analysis["ocr_text"].to_s,
        @analysis["video_ocr_text"].to_s,
        @analysis["transcript"].to_s,
        topics.join(" "),
        objects.join(" "),
        hashtags.join(" "),
        mentions.join(" ")
      ].join("\n")
    end

    def normalized_strings(value)
      Array(value).map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def detect_patterns(text:, patterns:)
      value = text.to_s
      Array(patterns).filter_map do |pattern|
        next unless pattern.is_a?(Regexp)
        next unless value.match?(pattern)

        pattern.source
      end
    end

    def detected_handles(corpus:, mentions:)
      handles = corpus.to_s.scan(HANDLE_REGEX).flatten.map { |value| normalize_username(value) }.reject(&:blank?)
      handles.concat(Array(mentions).map { |value| normalize_username(value.to_s.delete_prefix("@")) })
      handles.uniq.first(16)
    end

    def profile_tag_names
      @profile.profile_tags.pluck(:name).map { |value| value.to_s.downcase.strip }.reject(&:blank?)
    rescue StandardError
      []
    end

    def extract_source_owner_username
      candidates = []
      candidates << @metadata["owner_username"]
      candidates << @metadata["username"]
      candidates << @metadata["post_owner_username"]
      candidates << @metadata.dig("owner", "username")
      candidates << @metadata.dig("source_profile", "username")
      candidates << @analysis["source_owner_username"]
      candidates.map { |value| normalize_username(value) }.find(&:present?)
    end

    def normalize_username(value)
      value.to_s.downcase.strip.delete_prefix("@")
    end
  end
end
