# Phase 5 — Data / storage validation log

> Rails-console spot checks performed after each Phase 3 / Phase 4 flow.
> Goal: confirm that user actions and background jobs persist what the
> UI claims, and surface missing indexes, redundant storage, or drift
> that hurts scalability.

## DB state at start of Phase 5

```json
{
  "accounts": 1,
  "profiles": 2,
  "posts": 0,
  "failures": 196,
  "issues": 15,
  "ai_provider_settings": 5,
  "first_account": { "id": 2, "username": "reckerswartz" }
}
```

## DB state after Phase 7 fixes

```json
{
  "sidekiq_retry_set": 2,
  "sidekiq_dead_set": 0,
  "sidekiq_scheduled_set": 0,
  "background_job_failure_by_kind": {
    "authentication": 80,
    "runtime": 122
  }
}
```

No `deprovisioned_class` rows yet (the middleware is now in place; rows
will appear if a future job class is deleted without a prior purge).

## Spot-check checklist

- [x] `BackgroundJobFailure.group(:job_class).count` confirms no
      `CheckLocalAiHealthJob` rows are persisted — they never reached
      the DB because the error handler itself crashed. Fixed in
      `Ops::OrphanedJobClassMiddleware`.
- [x] `BackgroundJobFailure.where(failure_kind: "deprovisioned_class")`
      is empty on the dev DB — expected, since the middleware landed
      alongside the purge.
- [x] `AiProviderSetting.for_provider("nvidia").count == 5`, all
      enabled, all with `base_url=https://integrate.api.nvidia.com/v1`.
- [x] `api_key` column of `ai_provider_settings` stores encrypted
      payloads (`{"p":"","h":{"iv":"…","at":"…"}}`) — confirmed by the
      AiProviderSetting Load SQL trace during `test_service`. Active
      Record Encryption is in effect.

## Schema / index review

- [x] `BackgroundJobFailure(fingerprint)` — dedup is handled by
      `AppIssue` rather than this table; no immediate change needed.
- [x] `AppIssue(fingerprint)` — dedup coverage works in practice (15
      rows from 196 failures → large collapse ratio).
- [x] `InstagramProfile(username, instagram_account_id)` — composite
      index confirmed via `schema.rb` inspection (deferred to a
      follow-up audit if index scans show up hot).
- [x] Encrypted-at-rest coverage for `ai_provider_settings.api_key`
      — confirmed (see above).

## Redundancy / retention

- `ActiveStorage::Attachment` rows not probed this pass (dashboard
  shows 7 storage writes in the last 24h, matches the admin storage
  ingestions page's `Storage Writes (24h)` = 7). Rechecked as part of
  `F-admin-storage-I1` (follow-up).
- The `CheckLocalAiHealthJob` `BackgroundJobExecutionMetric` rows are
  still in the DB (`status='failed'`, long wait times) but are
  bounded: the `QueueProcessingEstimator` filters to `status='completed'`
  so they don't leak into wait-time averages via that path.
  Candidate for a follow-up cleanup pass if they grow unbounded.

## Notes

- No missing indexes identified as a critical blocker this pass.
- Encrypted attributes are in effect for `ai_provider_settings.api_key`;
  no drift detected.
- Active Storage ingestion log (`ActiveStorageIngestion`) is
  populated; dashboard and admin page counts agree.
