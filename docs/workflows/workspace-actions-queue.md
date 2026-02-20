# Workspace Actions Queue Workflow

Last updated: 2026-02-20

## Purpose

The workspace queue produces a prioritized list of recent posts that still need processing before an operator can select/send a high-quality comment.

Primary components:

- `Workspace::ActionsTodoQueueService`
- `WorkspaceProcessActionsTodoPostJob`

## 1) Queue Assembly

`ActionsTodoQueueService#fetch!`:

1. Loads recent candidate posts for the active account.
2. Filters out:
   - non-user content (stories/reposts flagged as non-actionable)
   - deleted-from-source rows
   - page/business-like profiles blocked by scan policy
   - posts already commented (`post_comment_sent` event lookup)
3. Derives post state:
   - `ready`
   - `waiting_media_download`
   - `waiting_post_analysis`
   - `waiting_build_history`
   - `queued_for_processing`
   - `running`, `failed`, or skipped statuses
4. Sorts by operational priority and recency.
5. Optionally enqueues processing jobs for top `requires_processing` items.

## 2) Per-Post Processor

`WorkspaceProcessActionsTodoPostJob#perform`:

1. Re-validates profile/post eligibility.
2. Marks row as running via `metadata["workspace_actions"]` lock fields.
3. Ensures video preview generation where needed.
4. If media missing:
   - queues `DownloadInstagramProfilePostMediaJob`
   - schedules a retry with `waiting_media_download`
5. If analysis incomplete:
   - queues `AnalyzeInstagramProfilePostJob` (comments disabled in this pass)
   - schedules retry with `waiting_post_analysis`
6. If analyzed but suggestions missing:
   - runs `Ai::PostCommentGenerationService`
7. If blocked by incomplete profile history evidence:
   - registers build-history fallback using `BuildInstagramProfileHistoryJob.enqueue_with_resume_if_needed!`
   - transitions to `waiting_build_history`
8. Marks terminal state (`ready` or `failed`) with explanation.

## 3) Workspace Metadata Contract

`instagram_profile_posts.metadata["workspace_actions"]` stores:

- status machine (`queued`, `running`, `waiting_*`, `ready`, `failed`, `skipped_*`)
- lock fields (`lock_until`)
- enqueue timestamps and job ids
- retry scheduling (`next_run_at`)
- error and suggestion counts

This metadata is the primary debug source for why a workspace card is not yet actionable.

## 4) Relationship to Build History

When `PostCommentGenerationService` blocks on missing required evidence:

- workspace job can register a resume job with build-history action log,
- `BuildInstagramProfileHistoryJob` eventually resumes deferred jobs once profile history is ready,
- workspace state is updated to reflect pending or resumed execution.

## 5) Operational Checks

When queue appears stuck:

1. Confirm `workspace_actions` metadata on affected post rows.
2. Check for active lock expiry (`lock_until`) and `next_run_at` delays.
3. Confirm post-analysis pipeline status is terminal.
4. Inspect build-history action logs for retry readiness.
