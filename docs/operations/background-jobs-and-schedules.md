# Background Jobs and Schedules

Last updated: 2026-02-21

## Queue Topology

Base Sidekiq queues (`config/sidekiq.yml`):

- `sync`
- `engagements`
- `story_downloads`
- `post_downloads`
- `profiles`
- `messages`
- `avatars`
- `maintenance`
- `default`

Dedicated capsules (`config/initializers/sidekiq.rb`):

- `ai` (legacy lane)
- `ai_visual_queue`
- `ai_face_queue`
- `ai_ocr_queue`
- `video_processing_queue`
- `ai_metadata_queue`
- `frame_generation`

## Development Startup Guardrails

- `bin/dev` validates local AI availability before worker startup when local AI is required.
- Default mode is `START_LOCAL_AI=auto` with `USE_LOCAL_AI_MICROSERVICE=true`, so the dev supervisor will attempt `bin/local_ai_services start` and fail fast if health checks do not pass.
- `bin/dev stop` / `bin/dev restart` only stop local AI services when they were started by that `bin/dev` session (ownership-safe shutdown).

## Local Worker Capacity Baseline

- Baseline Sidekiq concurrency defaults now target about **34 worker threads total** across the default pool and dedicated capsules.
- This profile is tuned for a local machine with ~20+ CPU threads and ~16 GB RAM, while keeping headroom for Rails web, local AI microservice, and Ollama.
- `bin/jobs` and the `worker` process in `Procfile.dev` now default `RAILS_MAX_THREADS=40` so Active Record pool capacity can keep pace with Sidekiq worker concurrency.
- Override any lane with `SIDEKIQ_*_CONCURRENCY` env vars when your machine is smaller/larger.

Useful checks:

- `bin/dev health` for combined supervisor/web/local-AI readiness.
- `bin/local_ai_services status` for AI-only health.
- `bin/local_ai_services restart` to restart AI independently without restarting web workers.

## Recurring Schedule Source

- Cron schedule is loaded from `config/sidekiq_schedule.yml` via sidekiq-cron.

Key recurring jobs:

- Continuous account processing:
  - `EnqueueContinuousAccountProcessingJob`
- Local AI health check:
  - `CheckAiMicroserviceHealthJob`
- Queue health check:
  - `CheckQueueHealthJob`
- Automatic retry of failed jobs:
  - `RetryFailedBackgroundJobsJob`
- Story auto-reply batch:
  - `EnqueueStoryAutoRepliesForAllAccountsJob`
- Feed auto-engagement batch:
  - `EnqueueFeedAutoEngagementForAllAccountsJob`
- Recent profile post scan batch:
  - `EnqueueRecentProfilePostScansForAllAccountsJob`

Feed capture autonomy:

- `EnqueueContinuousAccountProcessingJob` fans out to `ProcessInstagramAccountContinuouslyJob`.
- `Pipeline::AccountProcessingCoordinator` enqueues `CaptureHomeFeedJob` whenever `continuous_processing_next_feed_sync_at` is due.
- Default cadence target: every ~2 hours per account (`FEED_SYNC_INTERVAL`), with account-level jitter and local-AI health gating.
- `delay_seconds` is applied as inter-page pacing for timeline pagination to spread feed API fetches within each capture run.

Additional production jobs:

- `EnqueueFollowGraphSyncForAllAccountsJob`
- `EnqueueAvatarSyncForAllAccountsJob`
- `EnqueueProfileRefreshForAllAccountsJob`
- `PurgeExpiredInstagramPostMediaJob`

## Batched Scheduler Pattern

Jobs that fan out across accounts use `ScheduledAccountBatching`:

- load accounts in ascending-id batches,
- enqueue per-account jobs with deterministic staggered delay (slot-based wait + account-id jitter),
- self-schedule continuation with cursor when `has_more`.

This pattern prevents large one-shot queue spikes and keeps scheduling idempotent across large account sets.

Default stagger controls (override via ENV):

- `SCHEDULED_ACCOUNT_ENQUEUE_STAGGER_SECONDS` (default `4`)
- `SCHEDULED_ACCOUNT_ENQUEUE_JITTER_SECONDS` (default `2`)

Per-orchestrator overrides are also available, for example:

- `CONTINUOUS_PROCESSING_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `FOLLOW_GRAPH_SYNC_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `STORY_AUTO_REPLY_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `FEED_AUTO_ENGAGEMENT_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `PROFILE_SCAN_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `PROFILE_REFRESH_ACCOUNT_ENQUEUE_STAGGER_SECONDS`
- `AVATAR_SYNC_ACCOUNT_ENQUEUE_STAGGER_SECONDS`

Follow graph sync safety:

- Follow graph list collection stores per-account cursors and advances incrementally across runs.
- Partial runs are non-destructive: relationship flags are only cleared when a full snapshot is confirmed from the start cursor.

## Failure Capture and Retry Pipeline

### Capture

`ApplicationJob` around hook captures failures into `BackgroundJobFailure` with:

- job class, queue, args, error, account/profile context,
- failure kind (`authentication`, `transient`, `runtime`),
- retryable flag.

### Issue dedup

`Ops::IssueTracker` upserts `AppIssue` by fingerprint for:

- job failures,
- queue health degradation,
- AI service health outages.

### Manual/automatic retry

`Jobs::FailureRetry`:

- blocks authentication failures from retry,
- validates retry actionability,
- tracks retry_state metadata,
- supports automatic batch retry (`RetryFailedBackgroundJobsJob`).

For pipeline-step failures, retry is skipped when pipeline/step is already terminal.

## Live Operational Updates

ActionCable channel:

- `OperationsChannel`

Broadcaster:

- `Ops::LiveUpdateBroadcaster`

Primary topics:

- `jobs_changed`
- `job_failures_changed`
- `issues_changed`
- `dashboard_metrics_changed`
- `profiles_table_changed`

## Recommended Operator Screens

- Unified jobs dashboard:
  - `/admin/background_jobs`
- Failure table/detail:
  - `/admin/background_jobs/failures`
- Mission Control jobs UI:
  - `/admin/jobs`

## Admin Background Jobs Service Layer

Controller surface:

- `Admin::BackgroundJobsController` only orchestrates requests and delegates data shaping to services.

Service components:

- `Admin::BackgroundJobs::DashboardSnapshot`
  - resolves backend-specific queue/process/job snapshots
- `Admin::BackgroundJobs::JobSerializer`
  - normalizes Sidekiq and Solid Queue jobs into one UI contract
- `Admin::BackgroundJobs::RecentJobDetailsEnricher`
  - links recent jobs to action logs, failures, ingestions, LLM events, and API calls
- `Admin::BackgroundJobs::JobDetailsBuilder`
  - builds human-readable processing timeline + technical payloads for job details
- `Admin::BackgroundJobs::FailuresQuery`
  - applies tabulator filters, search, remote sort, and pagination for failure logs
- `Admin::BackgroundJobs::FailurePayloadBuilder`
  - serializes failure rows for tabulator JSON responses
- `Admin::BackgroundJobs::QueueClearer`
  - encapsulates queue reset/quiet logic per backend
- `Admin::BackgroundJobs::TabulatorParams`
  - isolates tabulator parameter parsing from controller logic

Interaction flow:

1. Controller action receives params and selects backend.
2. Query/snapshot service loads core rows with safe fallbacks.
3. Enricher links related records and delegates formatting to `JobDetailsBuilder`.
4. Payload builder emits stable JSON shape for tabulator clients.

## Extension Guidelines

- Add new dashboard data via a dedicated service class, then inject it into `DashboardSnapshot`; avoid re-growing controller logic.
- Keep backend-specific behavior behind `QueueClearer`/`DashboardSnapshot`; do not branch on backend in views or controllers.
- If a new table/UI needs tabulator filtering, create a query object with `call -> Result` contract and isolate parsing in a params object.
- Keep serializers pure (no writes, no broadcasts) so payload generation is deterministic and testable.
- Treat `JobDetailsBuilder` as read-only aggregation; if a new artifact source is needed, add a focused fallback/query method and cap record limits.
