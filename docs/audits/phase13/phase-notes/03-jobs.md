# Phase 3 — Background job behaviour log

> Triggers exercised during the audit, correlated with Sidekiq output,
> `BackgroundJobFailure` rows, and `/admin/background_jobs` state.

## Sidekiq state at the start of Phase 3

Snapshot taken via `Sidekiq::RetrySet / DeadSet / ScheduledSet` from a
Rails runner (2026-04-18):

```json
{
  "dead_set":     { "size": 0, "by_class": {}, "deprovisioned": {} },
  "retry_set":    {
    "size": 31,
    "by_class": {
      "CheckLocalAiHealthJob": 29,
      "GenerateProfilePostPreviewImageJob": 1,
      "AnalyzeAiFeatureEvidenceJob": 1
    },
    "deprovisioned": { "CheckLocalAiHealthJob": 29 }
  },
  "scheduled_set": { "size": 0, "by_class": {}, "deprovisioned": {} }
}
```

Every payload of `CheckLocalAiHealthJob` is **deprovisioned** — the
class was deleted in Phase 10 but the retry set still holds 29 live
entries. Each retry attempt raised
`ActiveJob::UnknownJobClassError: Failed to instantiate job, class
CheckLocalAiHealthJob doesn't exist`, then Sidekiq's top-level
`error_handlers` crashed with
`NameError: uninitialized constant CheckLocalAiHealthJob`, so the
failures never reached `BackgroundJobFailure` / `AppIssue`.

Direct evidence in `log/development.log` at `2026-04-18T10:22:10.689Z`:

```
[sidekiq] Failed job: ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper (83e8bd9b…) after 0.0s: ActiveJob::UnknownJobClassError: Failed to instantiate job, class `CheckLocalAiHealthJob` doesn't exist
[sidekiq] error handler failed for NameError: uninitialized constant CheckLocalAiHealthJob
[sidekiq] error handler failed for ActiveJob::UnknownJobClassError: Failed to instantiate job, class `CheckLocalAiHealthJob` doesn't exist
```

## Trigger log

| Timestamp | Page / command | Job / action | Outcome | Notes |
|---|---|---|---|---|
| 2026-04-18 10:31 UTC | `/ai_dashboard` → `Run test` | `POST /ai_dashboard/test_service` → `Ai::NvidiaClient#list_models!` | `200 OK in 647ms` | NVIDIA round-trip. Evidence in Phase 4 notes. |
| 2026-04-18 10:42 UTC | Rails runner | `rake jobs:purge_unresolvable` | dropped 30 payloads | CheckLocalAiHealthJob purge, confirmed via `Sidekiq::RetrySet.new.size = 2` after. |

## Silent-failure / stale-counter checks

- [x] Re-verified Phase 11 "24h failures dominated by deleted
  `CheckLocalAiHealthJob` probes" issue: confirmed the root cause and
  landed the fix (see `F-dashboard-C1` / `F-admin-background-jobs-C1`
  in `../FINDINGS.md`).
- [x] Middleware (`Ops::OrphanedJobClassMiddleware`) rescues future
  `UnknownJobClassError` and records `failure_kind=deprovisioned_class`
  rows so the error handler no longer dies silently.
- [x] `BackgroundJobFailure.excluding_deprovisioned` scope applied to
  dashboard 24h aggregator.

## Destructive actions NOT fired

| Page / button | Why deferred |
|---|---|
| Account show → `Manual Login` | fires a Playwright Chromium session, can collide with MCP sidecar |
| Account show → `Import Cookies` | overwrites the live `sessionid`, risks logging the account out |
| Admin failures → row `Retry` | bypasses deprovisioned_class classification on a stale payload, would re-enter the retry loop |
| Dashboard → row `Delete` | destroys the only `InstagramAccount` in the dev DB |
| AI Provider Settings → role `Enabled` toggle off | turns off LLM routing globally |

## Notes

- The dashboard `Retries` counter dropped from **29 → 2** after the
  purge (screenshot diff in
  `../screenshots/{before,after}/01-dashboard.png`).
- Two real entries remained after purge:
  `GenerateProfilePostPreviewImageJob` (blob-ID=2 unpreviewable) and
  `AnalyzeAiFeatureEvidenceJob` (days=14). The former is a
  `deleted_record`-class issue surfaced as follow-up finding
  `F-admin-failures-I3`.
