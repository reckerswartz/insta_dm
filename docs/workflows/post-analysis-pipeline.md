# Post Analysis Pipeline

Last updated: 2026-02-25

## Scope

This workflow handles profile-post media ingestion, multi-step AI extraction, metadata consolidation, and comment generation readiness.

Primary code surfaces:

- `DownloadInstagramProfilePostMediaJob`
- `AnalyzeInstagramProfilePostJob`
- `ProcessPostVisualAnalysisJob`
- `ProcessPostFaceAnalysisJob`
- `ProcessPostOcrAnalysisJob`
- `ProcessPostVideoAnalysisJob`
- `ProcessPostMetadataTaggingJob`
- `FinalizePostAnalysisPipelineJob`
- `Ai::PostAnalysisPipelineState`

## 1) Media Download and Queue Gate

`DownloadInstagramProfilePostMediaJob`:

1. Resolves source media URL from `source_media_url` or metadata fallbacks.
2. Applies `Instagram::MediaDownloadTrustPolicy` before any attach/download:
   - blocks promotional/ad URLs (`ad_related_media_source`, `promotional_media_host`, `promotional_media_query`)
   - blocks profiles not connected in follow graph (`profile_not_connected`)
3. Reuses local cache blobs when possible.
4. Performs integrity checks on existing blobs.
5. Writes download status to `post.metadata`.
6. Applies `Instagram::ProfileScanPolicy` before enqueueing analysis.
7. Enqueues `AnalyzeInstagramProfilePostJob` unless blocked/skipped.

Important outcomes:

- `download_status`: `downloaded`, `already_downloaded`, `skipped`, `failed`, `corrupt_detected`
- `download_skip_reason`: includes `profile_not_connected` and media-source policy reason codes
- `ai_status` may be set to `pending`

`Instagram::ProfileAnalysisCollector#sync_media!` applies the same trust policy for direct collector-driven media sync paths, so manual/profile dataset captures cannot bypass these source checks.

## 2) Orchestrator Boot

`AnalyzeInstagramProfilePostJob` (async mode):

1. Starts pipeline state via `Ai::PostAnalysisPipelineState.start!`.
2. Resolves required steps from task flags and media type.
3. Enqueues step jobs for required steps (`visual`, `face`, `ocr`, `video`).
4. Enqueues `FinalizePostAnalysisPipelineJob` poller.

Inline mode is used in selected fallback flows (for example history/build-history resume paths).

## 3) Step Execution Model

Each step job loads the same context by `(account_id, profile_id, post_id, pipeline_run_id)`.

Shared behavior:

- Skip execution if pipeline or step is already terminal.
- Mark step state transitions (`queued/running/succeeded/failed`) in metadata.
- Re-enqueue finalizer after each step run.

Step specifics:

- `visual` (`ai_visual_queue`):
  - calls `Ai::Runner` with visual-only provider options
  - writes baseline `analysis` and provider/model fields
- `face` (`ai_face_queue`):
  - runs `PostFaceRecognitionService`
  - writes face recognition metadata
- `ocr` (`ai_ocr_queue`):
  - can reuse OCR from face metadata cache
  - guarded by `Ops::ResourceGuard` defer/retry logic
- `video` (`video_processing_queue`):
  - routes through `PostVideoContextExtractionService`
  - runs lightweight pre-analysis before LLM vision (audio/text and existing structured signals can skip multimodal inference)
  - samples timestamp/key frames (instead of full-frame scans) for dynamic videos when visual enrichment is required
  - writes normalized video summary fields and merges topic/object/ocr signals
  - reuses cached `metadata["video_processing"]` for matching `media_fingerprint` + `extraction_profile`

## 4) Finalizer and Pipeline Completion

`FinalizePostAnalysisPipelineJob` is the single source of truth for terminal pipeline status.

Responsibilities:

1. Acquire short-lived finalizer lock in post metadata to avoid duplicate concurrent finalizers.
2. Enqueue `metadata` step only after core steps are terminal.
3. Mark stalled queued/running steps failed after timeout.
4. In lightweight mode, degrade failed `video` step to a metadata-backed fallback when visual context is already available (instead of looping expensive retries).
5. Poll until all required steps are terminal or max finalize attempts are exhausted.
6. Consolidate OCR/video metadata into canonical `post.analysis`.
7. Mark post `ai_status`:
   - `analyzed` when completion criteria are met
   - `failed` on degraded/failed terminal state

## 5) Metadata State Contracts

`post.metadata["ai_pipeline"]` contains:

- `run_id`, `status`, `required_steps`, `task_flags`
- `steps[step]`:
  - `status`, `attempts`, queue/job ids, timestamps, result payload, error
- optional `finalizer` lock metadata

Terminal pipeline statuses:

- `completed`
- `failed`

Step terminal statuses:

- `succeeded`
- `failed`
- `skipped`

## 6) Comment Generation Gate

Comment generation is not always part of the first pass.

- In many batch/workspace flows, analysis runs with `generate_comments=false`.
- Later, `ProcessPostMetadataTaggingJob` and/or `WorkspaceProcessActionsTodoPostJob` runs `Ai::PostCommentGenerationService`.
- Missing required evidence writes blocked policy reasons to:
  - `post.metadata["comment_generation_policy"]`

## 7) Failure and Retry Characteristics

- Video step timeout retries are fast-failed by default to prevent 10+ minute loops on constrained hardware.
- OCR/video can defer under resource pressure and requeue themselves.
- Video reinitialization attempts are configurable per-step, with `video` defaulting to no automatic reinitialize attempts.
- Video context extraction avoids repeated heavy work by reusing fingerprint-matched cached results.
- `Jobs::FailureRetry` avoids retrying pipeline step jobs when the underlying pipeline/step is already terminal.

## 8) Debugging Checklist

For a stuck post:

1. Inspect `post.ai_status` and `post.metadata["ai_pipeline"]`.
2. Confirm which step is non-terminal and whether attempts are exhausted.
3. Check `BackgroundJobFailure` rows for corresponding step job classes.
4. Validate queue pressure and capsule worker health for the affected queue.
