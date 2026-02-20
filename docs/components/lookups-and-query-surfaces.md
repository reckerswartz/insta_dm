# Lookups and Query Surfaces

Last updated: 2026-02-20

## Profile Table Lookups

Query service:

- `InstagramProfiles::ProfilesIndexQuery`

Capabilities:

- search by username/display name
- tri-state filters for `following`, `follows_you`, `mutual`, `can_message`
- Tabulator remote filters and sorters
- pagination normalization (`page`, `per_page/size`)

Primary source relation:

- `account.instagram_profiles`

## Profile Events Table Lookups

Query service:

- `InstagramProfiles::EventsQuery`

Capabilities:

- event kind filtering via Tabulator
- text query over `kind` and `external_id`
- remote sorting by `kind`, `occurred_at`, `detected_at`
- includes media attachments for preview/render paths

Primary source relation:

- `profile.instagram_profile_events`

## Account Story Archive API Lookups

Query service:

- `InstagramAccounts::StoryArchiveQuery`

Capabilities:

- paginated story-archive event retrieval
- optional day filter (`on=YYYY-MM-DD`)
- includes attached media and preview image fallbacks

Serializer:

- `InstagramAccounts::StoryArchiveItemSerializer`

## Dashboard Snapshot Lookups

Aggregator:

- `InstagramAccounts::DashboardSnapshotService`

Sources merged into one payload:

- `Ops::AccountIssues.for(account)`
- `Ops::Metrics.for_account(account)`
- latest `SyncRun`
- recent `BackgroundJobFailure`
- `Ops::AuditLogBuilder.for_account`
- `Workspace::ActionsTodoQueueService`
- `InstagramAccounts::SkipDiagnosticsService`

## Metadata Keys Used by Lookups and UI States

### Post-level metadata

- `ai_pipeline`
  - post pipeline progress/state
- `workspace_actions`
  - workspace queue state for post cards
- `comment_generation_policy`
  - blocked/missing-evidence explanations
- `ocr_analysis`
  - OCR extraction outputs and source
- `video_processing`
  - video extraction summary and merged context
- `history_build`
  - build-history and face-refresh orchestration fields

### Event-level metadata

- story ingestion and analysis payloads (`story_id`, media URLs, local intelligence)
- LLM generation details under `llm_comment_metadata`

### Profile-level operational fields

- DM interaction state:
  - `dm_interaction_state`, `dm_interaction_reason`, `dm_interaction_retry_after_at`
- Story interaction state:
  - `story_interaction_state`, `story_interaction_reason`, `story_interaction_retry_after_at`

## Common Lookup Pitfalls

- `can_message` alone is not enough; DM retry windows can temporarily block send attempts.
- `ai_status=analyzed` does not guarantee comment suggestions exist; inspect `comment_generation_policy`.
- `story archive` events can contain media but still be policy-blocked for LLM suggestion generation.
