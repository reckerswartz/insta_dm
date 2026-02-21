# Story Intelligence Pipeline

Last updated: 2026-02-21

Related reference:
- `docs/workflows/story-sync-api-reference.md`

## Story Processing Entry Paths

### A) Home carousel sync (account-level)

- Job: `SyncHomeStoryCarouselJob`
- Underlying client path: `Instagram::Client#sync_home_story_carousel!`
- Behavior:
  - traverses home story carousel
  - resolves canonical story context
  - applies skip logic (ads, out-of-network, reshare/external-profile indicators)
  - records rich story-related profile events

### B) Profile reel sync (profile-level)

- Job: `SyncInstagramProfileStoriesJob`
- Data source: `Instagram::Client#fetch_profile_story_dataset!`
- Behavior:
  - upserts profile snapshot fields
  - downloads/reuses story media
  - records `story_uploaded`, `story_viewed`, `story_downloaded` event stream
  - optionally queues reply actions when `auto_reply=true`

### C) Scheduled wrappers

- `SyncProfileStoriesForAccountJob` (batch within account)
- `EnqueueStoryAutoRepliesForAllAccountsJob` (all accounts via batched continuation)

## Story Ingestion to Persistent Story Tables

`StoryIngestionService#ingest!`:

1. Upserts `InstagramStory` by `(instagram_profile_id, story_id)`.
2. Persists source metadata and media URLs.
3. Attaches media blob when bytes are available.
4. Sets processing flags (`pending`/`processed`) with optional force-reprocess.
5. Enqueues `StoryProcessingJob` when processing is required.

## Story Processing Stages

`StoryProcessingService#process!`:

1. Loads media bytes (attached blob or fallback URL download).
2. Routes image vs video branch.
3. Video branch runs frame-change classification:
   - static-video => image-style processing from representative frame
   - dynamic-video => frame extraction + per-frame detection + audio extraction + transcription
4. Persists face detections into `InstagramStoryFace`.
5. Links/matches faces to `InstagramStoryPerson` using embeddings and vector matching.
6. Builds `content_understanding` and generated response suggestions.
7. Runs identity resolution for story participants (`FaceIdentityResolutionService`).
8. Updates story processing metadata and marks story processed.

## Story Event LLM Comment Path

Story archive events (`InstagramProfileEvent` kinds in `STORY_ARCHIVE_EVENT_KINDS`) support LLM comment generation.

Flow:

1. Event-specific context is built from local story intelligence + verified story insights.
2. Policy checks can skip generation when intelligence is missing or blocked.
3. `Ai::LocalEngagementCommentGenerator` generates candidates.
4. Candidates are relevance-ranked and best suggestion is stored on the event.

State fields on event:

- `llm_comment_status` (`not_requested`, `queued`, `running`, `completed`, `failed`, `skipped`)
- `llm_generated_comment`
- `llm_comment_metadata`

## Auto-Reply Gating

Reply queueing decisions in story sync jobs are based on:

- profile tags (`automatic_reply` variants)
- story interaction eligibility state
- model relevance and available suggestions
- skip reasons for policy and extraction constraints

## Debugging Signals

Useful records to inspect for story failures:

- `InstagramProfileActionLog` with action `sync_stories` / `auto_story_reply`
- story event rows (`story_*` kinds) and metadata reasons
- `InstagramStory.processing_status` and `InstagramStory.metadata`
- `BackgroundJobFailure` entries for `SyncInstagramProfileStoriesJob` / `StoryProcessingJob`
