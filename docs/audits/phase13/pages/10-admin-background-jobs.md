# Admin Background Jobs — `/admin/background_jobs` → `admin/background_jobs#dashboard`

## Snapshot

- **URL:** `/admin/background_jobs`
- **View:** `app/views/admin/background_jobs/dashboard.html.erb`
- **Screenshot (before):** `../screenshots/before/10-admin-background-jobs.png`
- **DB state:** Sidekiq live. 30 failed jobs in Sidekiq dead set
  (mission control reports `Failed jobs (30)`). 196
  `BackgroundJobFailure` rows, 15 `AppIssue` rows. Queues mostly empty,
  29 retries enqueued.
- **Captured at:** 2026-04-18 10:21 UTC
- **Live log evidence:** Sidekiq is actively failing `CheckLocalAiHealthJob`
  with `ActiveJob::UnknownJobClassError` (confirmed in
  `log/development.log` at 2026-04-18T10:22:10Z).

## Clarity of content

- Operators can see per-queue state, worker pool, recent processed
  count, failure-kind breakdown, and drill through to the tabulator
  failure table.

## UI / UX consistency

- This is the largest page by node count in the walk (YAML dump was
  ~116 KB). The amount of information displayed could be split across
  tabs.

## Missing or redundant elements

- Does not expose the active stale-class retry loop as a first-class
  banner. The operator has to read the 30 sidekiq-dead-set jobs and
  infer it.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Any queue row link | click | drill down to mission control queue | Phase 2 ✅ |
| `Refresh` | click | re-render dashboard snapshot | Phase 2 ✅ |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| `Clear all background jobs` (if exposed) | wipes the queue, irreversible |

## Background jobs triggered

- None directly from this page. Retry actions are exercised on the
  failures detail page (see page 11).

## LLM calls observed

- None.

## Data / storage validation

- `BackgroundJobFailure.count = 196` — includes failures that reference
  the deleted class.
- `ActiveJob::Base.lookup("CheckLocalAiHealthJob")` raises
  `NameError`. Any retry attempt also blows up the error handler
  (`error handler failed for NameError: uninitialized constant
  CheckLocalAiHealthJob`).

## Findings

### Critical

- **`F-admin-background-jobs-C1`** — Stale-class retry loop: Sidekiq
  keeps retrying payloads for `CheckLocalAiHealthJob` (deleted Phase 10)
  because the dead-set / retry-set still holds them. Each retry raises
  `ActiveJob::UnknownJobClassError`, and the error handler then raises
  `NameError: uninitialized constant CheckLocalAiHealthJob`. The
  dashboard does not surface this and the failures never migrate to
  the `AppIssue` tracker because the issue-dedup path itself depends
  on resolving the class.
  Source: `log/development.log`, `app/jobs/application_job.rb` around
  hook, `app/services/ops/issue_tracker.rb`. Same root cause as
  `F-dashboard-C1`.

### Improvement

- **`F-admin-background-jobs-I1`** — Add a banner at the top of the
  dashboard that counts and surfaces "unresolvable job class" failures
  with a one-click purge action.

### Optional

- **`F-admin-background-jobs-O1`** — Consider splitting the dashboard
  into tabs (Overview / Failures / Queues / Metrics) to reduce page
  weight.

## Proposed fixes

### Will land in this branch

- `Jobs::OrphanedClassCleanup.call!` service + rake task
  (`rake jobs:purge_unresolvable`) + Sidekiq middleware that classifies
  `ActiveJob::UnknownJobClassError` as `failure_kind=deprovisioned_class`
  and marks the failure `retryable: false` without trying to
  reinstantiate.
- Add a "Deprovisioned job class" banner to the dashboard when
  `BackgroundJobFailure.where(failure_kind: "deprovisioned_class")
  .exists?`.

### Deferred

- Tab split of the dashboard (Phase 14 candidate, bigger refactor).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
