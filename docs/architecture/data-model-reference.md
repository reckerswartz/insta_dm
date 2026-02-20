# Data Model Reference

Last updated: 2026-02-20

This document maps every application table, its purpose, key fields, and relationships. Use it to understand where data lives and how entities connect.

## Core Instagram Entities

### `instagram_accounts`

Central authentication and automation hub. One row per managed Instagram identity.

| Field group | Key fields | Purpose |
|---|---|---|
| Identity | `username` (unique) | Account selector |
| Auth | `cookies_json`, `login_state`, `user_agent` | Encrypted session state |
| Continuous processing | `continuous_processing_state`, `*_next_*_at`, `*_heartbeat_at`, `*_failure_count`, `*_retry_after_at` | Coordinator state machine for automated story/feed/profile work |

Relationships: parent of `instagram_profiles`, `instagram_messages`, `instagram_posts`, `sync_runs`, `recipients`, `conversation_peers`, all AI/insight tables.

---

### `instagram_profiles`

One row per discovered Instagram user within an account's network.

| Field group | Key fields | Purpose |
|---|---|---|
| Identity | `username` (unique per account), `ig_user_id`, `display_name`, `bio` | Profile snapshot |
| Follow graph | `following`, `follows_you` | Mutuals derived where both true |
| DM state | `dm_interaction_state`, `dm_interaction_reason`, `dm_interaction_retry_after_at` | Messageability tracking with retry windows |
| Story state | `story_interaction_state`, `story_interaction_reason`, `story_interaction_retry_after_at` | Story reply eligibility |
| AI estimates | `ai_estimated_age`, `ai_estimated_gender`, `ai_estimated_location`, `ai_persona_summary`, `ai_last_analyzed_at` | Demographics from `ProfileDemographicsAggregator` |
| Media | `profile_pic_url`, `avatar_url_fingerprint`, `avatar_synced_at` | Avatar tracking |

Uniqueness: `(instagram_account_id, username)`.

---

### `instagram_profile_posts`

Captured posts from a profile, used for AI analysis and workspace actions.

| Field group | Key fields | Purpose |
|---|---|---|
| Identity | `shortcode` (unique per profile), `permalink`, `source_media_url` | Post locator |
| Content | `caption`, `likes_count`, `comments_count`, `taken_at` | Post snapshot |
| AI pipeline | `ai_status` (`pending`/`analyzed`/`failed`), `ai_provider`, `ai_model`, `analysis` (JSON), `analyzed_at` | Pipeline terminal state |
| Metadata | `metadata` (JSON) | Carries `ai_pipeline`, `workspace_actions`, `comment_generation_policy`, `history_build`, `ocr_analysis`, `video_processing` contracts |
| Media | Active Storage `media` attachment, `media_url_fingerprint` | Downloaded post image/video |

Uniqueness: `(instagram_profile_id, shortcode)`.

---

### `instagram_profile_events`

Immutable event journal for story/comment/post activity per profile.

| Field group | Key fields | Purpose |
|---|---|---|
| Event identity | `kind`, `external_id` (unique per profile+kind), `occurred_at`, `detected_at` | Event dedup and ordering |
| LLM comment | `llm_comment_status`, `llm_generated_comment`, `llm_comment_metadata`, `llm_comment_relevance_score` | Story archive comment generation lifecycle |
| Metadata | `metadata` (JSON) | Story ingestion payloads, media URLs, local intelligence |

Event kinds include: `story_uploaded`, `story_viewed`, `story_downloaded`, `post_liked`, `post_comment_sent`, and more.

---

### `instagram_posts`

Feed-level posts captured from home feed engagement.

| Key fields | Purpose |
|---|---|
| `shortcode` (unique per account), `author_username`, `caption` | Post identity |
| `status` (`pending`/`analyzed`/`failed`), `analysis` (JSON) | AI state |
| `media_url`, `post_kind`, `purge_at` | Media lifecycle |

---

### `instagram_messages`

Outgoing/incoming DMs per profile.

| Key fields | Purpose |
|---|---|
| `body`, `direction` (`outgoing`/`incoming`), `status` (`queued`/`sent`/`failed`), `sent_at` | Message lifecycle |
| `error_message` | Failure diagnostics |

---

### `instagram_profile_post_comments`

Comments captured from profile posts during post-capture flow.

| Key fields | Purpose |
|---|---|
| `body`, `author_username`, `commented_at` | Comment content |
| `instagram_profile_post_id` | Parent post |

---

## AI and Insight Tables

### `ai_analyses`

Polymorphic raw AI run history. Every AI inference creates one row.

| Key fields | Purpose |
|---|---|
| `analyzable_type`/`analyzable_id` | Polymorphic target (profile, post, etc.) |
| `purpose` | Analysis type identifier |
| `provider`, `model` | Which AI ran this |
| `prompt`, `response_text`, `analysis` (JSON) | Full I/O |
| `status` (`queued`/`running`/`completed`/`failed`) | Run lifecycle |
| `media_fingerprint`, `cache_hit`, `cached_from_ai_analysis_id` | Dedup/cache reuse |
| `confidence_score`, `evidence_count`, `signals_detected_count`, `input_completeness_score` | Quality metrics |
| `prompt_version`, `schema_version` | Versioning |

---

### `ai_api_calls`

Per-call usage tracking for AI operations.

| Key fields | Purpose |
|---|---|
| `provider`, `operation`, `category` | Call classification |
| `input_tokens`, `output_tokens`, `total_tokens`, `request_units` | Usage metrics |
| `latency_ms`, `http_status`, `status` | Performance |
| `occurred_at` | Timestamp for rate-limit windows |

---

### `ai_provider_settings`

Provider configuration and enablement.

| Key fields | Purpose |
|---|---|
| `provider` (unique), `enabled`, `priority` | Provider selection |
| `config` (JSON), `api_key` | Provider-specific configuration |

---

### Materialized Insight Tables

These tables project query-friendly data from raw `ai_analyses` records:

| Table | Purpose | Key fields |
|---|---|---|
| `instagram_profile_insights` | Profile-level AI summary | `profile_type`, `tone`, `engagement_style`, `messageability_score`, `primary_language` |
| `instagram_profile_message_strategies` | Messaging guidance | `best_topics`, `avoid_topics`, `dos`, `donts`, `opener_templates`, `comment_templates` |
| `instagram_profile_signal_evidences` | Individual signal observations | `signal_type`, `value`, `confidence`, `evidence_text`, `source_type` |
| `instagram_post_insights` | Post-level AI summary | `image_description`, `comment_suggestions`, `sentiment`, `topics`, `engagement_score` |
| `instagram_post_entities` | Extracted entities from posts | `entity_type`, `value`, `confidence`, `evidence_text` |

All link back to `ai_analyses` via `ai_analysis_id`.

---

## Story Intelligence Tables

### `instagram_stories`

Persisted story media with processing state.

| Key fields | Purpose |
|---|---|
| `story_id` (unique per profile), `media_type`, `taken_at`, `expires_at` | Story identity |
| `image_url`, `video_url`, `media_url`, `duration_seconds` | Media URLs |
| `processing_status` (`pending`/`processed`/`failed`), `processed_at` | Pipeline state |
| `metadata` (JSON) | Processing outputs including `content_understanding` |
| `source_event_id` | Link to originating `instagram_profile_event` |
| Active Storage `media` attachment | Downloaded media blob |

---

### `instagram_story_faces`

Face detections within stories.

| Key fields | Purpose |
|---|---|
| `bounding_box` (JSON), `detector_confidence` | Detection geometry |
| `embedding` (JSON), `embedding_version` | Face embedding for matching |
| `role` (`unknown`/`primary`/`secondary_person`) | Identity classification |
| `instagram_story_person_id`, `match_similarity` | Link to person cluster |

---

### `instagram_story_people`

Person clusters built from face matching across stories.

| Key fields | Purpose |
|---|---|
| `label`, `role` (`secondary_person`/`primary_person`/`profile_owner`) | Identity state |
| `canonical_embedding` (JSON), `appearance_count` | Cluster centroid and frequency |
| `first_seen_at`, `last_seen_at` | Temporal range |
| `metadata` (JSON) | Linked usernames, relationship classification, coappearance stats |

---

### `instagram_post_faces`

Face detections within profile posts (mirrors `instagram_story_faces` structure).

---

### `instagram_profile_behavior_profiles`

Aggregated behavioral profile from story patterns.

| Key fields | Purpose |
|---|---|
| `behavioral_summary` (JSON), `activity_score` | Pattern summary |

One per profile (unique index).

---

## Operational Tables

### `background_job_failures`

Every job failure is persisted here by the `ApplicationJob` around hook.

| Key fields | Purpose |
|---|---|
| `job_class`, `queue_name`, `active_job_id` | Job identity |
| `error_class`, `error_message`, `backtrace` | Error details |
| `failure_kind` (`authentication`/`transient`/`runtime`) | Classification |
| `retryable` | Whether `Jobs::FailureRetry` can retry this |
| `metadata` (JSON) | Context, timing, execution count |

---

### `app_issues`

Deduplicated issues derived from job failures, queue health, and AI health checks.

| Key fields | Purpose |
|---|---|
| `fingerprint` (unique) | Dedup key |
| `issue_type`, `severity`, `status` (`open`/`resolved`) | Classification |
| `occurrences`, `first_seen_at`, `last_seen_at` | Frequency tracking |
| `title`, `details`, `resolution_notes` | Human-readable context |

---

### `sync_runs`

Lifecycle tracking for follow-graph syncs and continuous-processing runs.

| Key fields | Purpose |
|---|---|
| `kind` (`follow_graph`/`continuous_processing`) | Run type |
| `status` (`queued`/`running`/`succeeded`/`failed`) | Lifecycle |
| `stats_json` | Structured job-level stats |

---

### `instagram_profile_action_logs`

Per-profile action audit trail.

| Key fields | Purpose |
|---|---|
| `action` (e.g. `fetch_details`, `sync_stories`, `analyze`) | Action type |
| `status` (`queued`/`running`/`succeeded`/`failed`) | Lifecycle |
| `metadata` (JSON) | Job IDs, queue info, action-specific payloads |
| `trigger_source` | What initiated the action |

---

### `instagram_profile_history_chunks`

Chunked narrative history for profiles, used in comment generation context.

| Key fields | Purpose |
|---|---|
| `sequence` (unique per profile), `content` | Ordered narrative text |
| `word_count`, `entry_count` | Chunk metrics |
| `starts_at`, `ends_at` | Temporal coverage |

---

### Other Tables

| Table | Purpose |
|---|---|
| `instagram_profile_taggings` / `profile_tags` | Tagging system for profiles (e.g. `automatic_reply`, `profile_scan_excluded`) |
| `instagram_profile_analyses` | Legacy profile analysis records (pre-`ai_analyses` migration) |
| `recipients` | Legacy conversation/story recipients for bulk DM sending |
| `conversation_peers` | Inbox-discovered conversation partners |
| `active_storage_ingestions` | Audit trail for Active Storage blob creation by jobs |

---

## JSON Metadata Contract Index

| Table | Metadata key | Purpose | Documented in |
|---|---|---|---|
| `instagram_profile_posts` | `ai_pipeline` | Post analysis pipeline state machine | `docs/workflows/post-analysis-pipeline.md` |
| `instagram_profile_posts` | `workspace_actions` | Workspace queue state | `docs/workflows/workspace-actions-queue.md` |
| `instagram_profile_posts` | `comment_generation_policy` | Why comment gen was blocked/allowed | `docs/workflows/post-analysis-pipeline.md` |
| `instagram_profile_posts` | `history_build` | Build-history orchestration state | `docs/workflows/workspace-actions-queue.md` |
| `instagram_profile_posts` | `ocr_analysis` | OCR extraction outputs | `docs/workflows/post-analysis-pipeline.md` |
| `instagram_profile_posts` | `video_processing` | Video extraction summary | `docs/workflows/post-analysis-pipeline.md` |
| `instagram_profile_events` | `metadata` | Story ingestion, media, local intelligence | `docs/workflows/story-intelligence-pipeline.md` |
| `instagram_profile_events` | `llm_comment_metadata` | LLM generation details | `docs/workflows/story-intelligence-pipeline.md` |
| `instagram_stories` | `metadata` | Processing outputs, `content_understanding` | `docs/workflows/story-intelligence-pipeline.md` |
| `instagram_story_people` | `metadata` | Linked usernames, relationships, coappearance | `docs/architecture/face-identity-and-video-pipeline.md` |
