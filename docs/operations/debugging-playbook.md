# Debugging Playbook

Last updated: 2026-02-20

## Baseline Checks

1. Confirm worker/scheduler are running:

```bash
bin/dev
# or jobs-only
bin/jobs
```

2. Confirm app health:

```bash
curl -sS http://127.0.0.1:3000/up
```

3. Open operational dashboards:

- `/admin/background_jobs`
- `/admin/background_jobs/failures`

## Scenario: Post Analysis Stuck in Running/Pending

Where to inspect:

- `instagram_profile_posts.ai_status`
- `instagram_profile_posts.metadata->'ai_pipeline'`
- `background_job_failures` for step job classes

Checks:

1. Verify current pipeline `run_id` and non-terminal step.
2. Check step `attempts` and last error in `ai_pipeline.steps`.
3. Confirm queue capsule availability for that step queue.
4. If pipeline is terminal but UI shows stale data, refresh profile/post frame endpoint.

## Scenario: Workspace Item Never Becomes Ready

Where to inspect:

- `instagram_profile_posts.metadata->'workspace_actions'`
- `instagram_profile_posts.metadata->'comment_generation_policy'`
- related `build_history` action logs

Checks:

1. If status is `waiting_media_download`, verify media attachment/job failures.
2. If status is `waiting_post_analysis`, inspect `ai_pipeline` state.
3. If status is `waiting_build_history`, inspect latest `build_history` action log and reason codes.
4. If status is `failed`, use `last_error` and associated `BackgroundJobFailure` rows.

## Scenario: Continuous Processing Not Advancing

Where to inspect:

- `instagram_accounts.continuous_processing_*` fields
- `sync_runs` kind `continuous_processing`
- failures for `ProcessInstagramAccountContinuouslyJob`

Checks:

1. `continuous_processing_enabled` is true.
2. `continuous_processing_retry_after_at` is not in the future.
3. `continuous_processing_state` is not stuck in running with fresh heartbeat.
4. Local AI health status is not stale/unhealthy if story/feed/profile scan work is expected.

## Scenario: Story Pipeline Failures

Where to inspect:

- profile action logs (`sync_stories`, `auto_story_reply`)
- `instagram_profile_events` story_* kinds and metadata skip/failure reasons
- `instagram_stories.processing_status`

Checks:

1. Confirm story dataset returned story IDs and media URLs.
2. Confirm skip reasons are expected (`api_should_skip`, out-of-network, retry windows).
3. If processing fails, inspect `InstagramStory.metadata["processing_error"]` and linked job failure.
4. Verify local AI microservice and ffmpeg/whisper dependencies for video paths.

## Scenario: DM Send Failures/Retry Pending

Where to inspect:

- `instagram_messages.status/error_message`
- profile DM state fields (`dm_interaction_*`)
- failures for `SendInstagramMessageJob`

Checks:

1. If retry pending, inspect `dm_interaction_retry_after_at`.
2. Check whether API-first send failed and UI fallback also failed.
3. Validate account session cookies are authenticated.

## Fast Rails Console Snippets

```ruby
# Latest failed jobs
BackgroundJobFailure.order(occurred_at: :desc).limit(20).pluck(:job_class, :error_class, :error_message, :occurred_at)

# Post pipeline snapshot
post = InstagramProfilePost.find(<id>)
post.metadata["ai_pipeline"]

# Workspace state snapshot
post.metadata["workspace_actions"]

# Continuous-processing state
acct = InstagramAccount.find(<id>)
acct.slice(
  :continuous_processing_enabled,
  :continuous_processing_state,
  :continuous_processing_retry_after_at,
  :continuous_processing_last_heartbeat_at,
  :continuous_processing_next_story_sync_at,
  :continuous_processing_next_feed_sync_at,
  :continuous_processing_next_profile_scan_at
)
```
