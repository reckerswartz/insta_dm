# Account Sync and Processing Workflow

Last updated: 2026-02-25

## 1) Follow Graph Sync (Primary Network Refresh)

Entry points:

- UI/manual trigger: `POST /follow_graph_sync` (`SyncsController#create` is legacy `sync_data!`; follow-graph uses `SyncFollowGraphJob` path)
- Scheduled/all-accounts trigger:
  - `EnqueueFollowGraphSyncForAllAccountsJob` -> `SyncFollowGraphJob`

Core flow:

1. `SyncFollowGraphJob` creates/updates a `SyncRun` lifecycle (`queued -> running -> succeeded/failed`).
2. `Instagram::Client#sync_follow_graph!` executes:
   - inbox user discovery (`collect_conversation_users`)
   - story tray discovery (`collect_story_users`)
   - followers/following fetch (`collect_follow_list`)
3. Profile flags are rebuilt transactionally:
   - reset `following/follows_you`
   - upsert latest follower/following lists
   - set mutuals implicitly where both flags are true
4. Inbox-derived users are marked DM-messageable (`dm_interaction_state=messageable`, retry cleared).
5. Story tray visibility updates `last_story_seen_at` and emits `story_seen` events.

Key code:

- `app/jobs/sync_follow_graph_job.rb`
- `app/services/instagram/client.rb` (`sync_follow_graph!`)

## 2) Profile Refresh and Messageability

Entry points:

- Manual per-profile action:
  - `FetchInstagramProfileDetailsJob`
  - `VerifyInstagramMessageabilityJob`
- Batch refresh:
  - `SyncNextProfilesForAccountJob`
  - `EnqueueProfileRefreshForAllAccountsJob`

Core flow (`FetchInstagramProfileDetailsJob`):

1. Calls `Instagram::Client#fetch_profile_details_and_verify_messageability!`.
2. Updates profile snapshot fields:
   - display name, bio, avatar URL, followers count, last post timestamp
   - DM interaction state + retry timestamps
3. Applies scan-policy tag behavior (`profile_scan_excluded` for page-like accounts).
4. Queues avatar refresh if avatar fingerprint changed.
5. Avatar download path enforces `Instagram::MediaDownloadTrustPolicy`:
   - skips promotional/ad avatar URLs
   - skips profiles outside follow graph/self/trusted tags (`profile_not_connected`)

Key code:

- `app/jobs/fetch_instagram_profile_details_job.rb`
- `app/jobs/verify_instagram_messageability_job.rb`

## 3) Continuous Account Processing Loop

Entry points:

- Scheduler job: `EnqueueContinuousAccountProcessingJob`
- Per-account worker: `ProcessInstagramAccountContinuouslyJob`
- Manual trigger: `POST /instagram_accounts/:id/run_continuous_processing`

Coordinator:

- `Pipeline::AccountProcessingCoordinator` decides due work based on per-account next-run timestamps.
- Health gate: `Ops::LocalAiHealth.check`.
- Enqueues when due:
  - stories: `SyncHomeStoryCarouselJob`
  - feed engagement: `AutoEngageHomeFeedJob`
  - profile scan: `EnqueueRecentProfilePostScansForAccountJob`
  - fallback when AI unhealthy: `SyncNextProfilesForAccountJob`
  - workspace refresh: `Workspace::ActionsTodoQueueService`

Concurrency and recovery guarantees:

- Row lock gate on account state prevents duplicate in-flight runs.
- Heartbeat-based stale-run detection (`RUNNING_STALE_AFTER`).
- Failure backoff persisted on account (`continuous_processing_retry_after_at`, failure count).

Key code:

- `app/jobs/enqueue_continuous_account_processing_job.rb`
- `app/jobs/process_instagram_account_continuously_job.rb`
- `app/services/pipeline/account_processing_coordinator.rb`

## 4) Direct Messaging Delivery

Entry points:

- Single profile message:
  - `InstagramProfileMessagesController#create` -> `SendInstagramMessageJob`
- Batch recipient send:
  - `MessagesController#create` -> `Instagram::Client#send_messages!`

Send strategy:

1. API-first attempt (`send_direct_message_via_api!` using `direct_v2` endpoints).
2. Fallback to Selenium UI composer when API path fails.
3. Profile DM interaction state is updated for retry windows and failure reasons.

Key code:

- `app/jobs/send_instagram_message_job.rb`
- `app/services/instagram/client.rb` (`send_message_to_user!`, `send_direct_message_via_api!`)

## 5) Operational Signals for This Workflow

Debug surfaces:

- `SyncRun` rows for follow-graph and continuous-processing runs.
- `InstagramProfileActionLog` rows for profile-level actions.
- `BackgroundJobFailure` for failed jobs (plus `AppIssue` deduped issue state).
- Turbo/ActionCable notifications and `Ops::LiveUpdateBroadcaster` events.

Useful relationships:

- `SyncRun.stats_json` stores structured job-level stats.
- `InstagramProfileActionLog.metadata` carries queue/job ids and per-action payloads.
