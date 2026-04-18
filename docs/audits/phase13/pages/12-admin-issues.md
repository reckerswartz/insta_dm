# Admin Issues — `/admin/issues` → `admin/issues#index`

## Snapshot

- **URL:** `/admin/issues`
- **View:** `app/views/admin/issues/index.html.erb`
- **Screenshot (before):** `../screenshots/before/12-admin-issues.png`
- **DB state:** `AppIssue.count = 15`. The Tabulator grid initially
  renders 0 rows with "Loading…" (async JSON hydrate).
- **Captured at:** 2026-04-18 10:22 UTC
- **Console:** 1 JS error (same Tabulator pattern).

## Clarity of content

- Header copy is clear.
- Column set (Last Seen / Issue / Type / Source / Severity / Status /
  Occurrences / Context / Summary / Actions) matches the
  `Ops::IssueTracker` schema described in
  `docs/operations/background-jobs-and-schedules.md`.

## UI / UX consistency

- Matches Failures index layout.

## Missing or redundant elements

- No severity summary tile row.
- No link back to the originating `BackgroundJobFailure` fingerprint.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Tabulator filters | fill | narrow grid | Phase 2 ✅ |
| Inline `Status` dropdown | change | `PATCH /admin/issues/:id` | Phase 2 |
| `Retry job` button | click | `POST /admin/issues/:id/retry_job` | Phase 3 candidate (deferred to avoid stale-class loop) |

Destructive controls: none surfaced on this index (status changes are
recoverable).

## Background jobs triggered

- Deferred to Phase 3.

## LLM calls observed

- None.

## Data / storage validation

- `AppIssue.count = 15`; fingerprint column is populated. Need Phase 5
  spot-check that `AppIssue.fingerprint` has a unique index and that
  dedup actually collapses.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-admin-issues-I1`** — Add severity tile row (`error / warn / info`
  counts) at the top.
- **`F-admin-issues-I2`** — Link Issue summary to the matching
  `BackgroundJobFailure` rows sharing the same fingerprint.

### Optional

- **`F-admin-issues-O1`** — 1 JS console error (shared Tabulator fix).

## Proposed fixes

### Will land in this branch

- Severity tile row on the issues index.
- In the JSON payload builder, include a `related_failure_count` field
  and render it as a Tabulator column → `/admin/background_jobs/failures?fingerprint=…`.

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
