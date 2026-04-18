# Phase 3 — Background job behaviour log

> Triggers exercised during the audit, correlated with Sidekiq output,
> `BackgroundJobFailure` rows, and `/admin/background_jobs` state.

## Trigger log

| Timestamp | Page / button | Job enqueued | Queue | Completion | Runtime | Log excerpt |
|---|---|---|---|---|---|---|
| *(empty)* | | | | | | |

## Silent-failure / stale-counter checks

- [ ] Re-verify Phase 11 "24h failures dominated by deleted
  `CheckLocalAiHealthJob` probes" issue against the current dashboard.
- [ ] Confirm every triggered job surfaces an outcome in
  `/admin/background_jobs` within its retry window.
- [ ] Sample `BackgroundJobFailure#fingerprint` + `AppIssue#fingerprint`
  for dedup coverage.

## Notes

*(populated during walk)*
