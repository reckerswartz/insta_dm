# Background Jobs and Schedules

Last updated: 2026-02-20

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
- Additional production jobs:
  - `EnqueueFollowGraphSyncForAllAccountsJob`
  - `EnqueueAvatarSyncForAllAccountsJob`
  - `EnqueueProfileRefreshForAllAccountsJob`
  - `PurgeExpiredInstagramPostMediaJob`

## Batched Scheduler Pattern

Jobs that fan out across accounts use `ScheduledAccountBatching`:

- load accounts in ascending-id batches,
- enqueue per-account jobs,
- self-schedule continuation with cursor when `has_more`.

This pattern prevents large one-shot queue spikes and keeps scheduling idempotent across large account sets.

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
