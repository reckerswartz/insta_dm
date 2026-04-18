# Admin Failures — `/admin/background_jobs/failures` + `/:id`

## Snapshot

- **URL:** `/admin/background_jobs/failures` and
  `/admin/background_jobs/failures/212`
- **View:** `app/views/admin/background_jobs/failures.html.erb` and
  `app/views/admin/background_jobs/failure.html.erb`
- **Screenshots (before):**
  - `../screenshots/before/11-admin-failures.png`
  - `../screenshots/before/11b-admin-failure-detail.png`
- **DB state:** `BackgroundJobFailure.count = 196`. The tabulator grid
  initially renders 0 rows with "Loading…" — data is fetched via a JSON
  endpoint.
- **Captured at:** 2026-04-18 10:21–10:22 UTC
- **Console:** 1 JS error on page load (likely same Tabulator pattern
  already flagged).

## Clarity of content

- Top copy ("Application-level failure records (persisted on exception)")
  is precise.
- Detail page ID 212 (`GenerateProfilePostPreviewImageJob`) shows
  `ActiveStorage::UnpreviewableError: No previewer found for blob with
  ID=2 and content_type=video/mp4`, correctly marked
  `Retryable now: No`, `Failure kind: runtime`, with ActiveJob ID,
  Sidekiq job ID, and queue (`frame_generation`). Good operator hygiene.

## UI / UX consistency

- Matches the profiles / posts / issues tabulator layout.
- Detail page uses the same card style as admin issues.

## Missing or redundant elements

- Index page doesn't expose a "failure kind" summary tile at the top
  (how many auth vs runtime vs deprovisioned_class).
- Detail page `Metadata` block is a raw `<details>` with no hinting on
  what fields are typically important (fingerprint, retry state,
  prediction error). Small affordance issue.
- No "related failures" section on the detail page (failures sharing
  the same fingerprint).

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Tabulator header filters | fill | narrow grid | Phase 2 ✅ empty row state |
| Row `Retry` action | click | `POST retry_failure` | Phase 3 candidate (but fingerprint-aware; deferred to avoid triggering new 500s) |
| Detail page `Arguments` / `Metadata` / `Backtrace` toggles | click | expand | Phase 2 ✅ |
| `Back to Failures` link | click | return to index | Phase 2 ✅ |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| Bulk `Clear all jobs` (if present on parent admin page) | wipes the queue |
| Retry that reruns a live Instagram browser job | side-effecting |

## Background jobs triggered

- Deferred to Phase 3.

## LLM calls observed

- None.

## Data / storage validation

- `BackgroundJobFailure(212)` has `failure_kind=runtime`,
  `retryable=false`, `job_class=GenerateProfilePostPreviewImageJob`,
  `queue_name=frame_generation`, `error_class=ActiveStorage::UnpreviewableError`.
- Spot check: the failure's `arguments` is
  `[{"instagram_profile_post_id":1}]` — the post does NOT exist anymore
  (`InstagramPost.count=0`). So the job itself is orphaned. This is the
  same class of problem as the `CheckLocalAiHealthJob` stale-class
  issue, just one level up — not a stale *class*, but a stale *record
  reference*.

## Findings

### Critical

- *(none beyond the already-filed `F-admin-background-jobs-C1`)*

### Improvement

- **`F-admin-failures-I1`** — Add a summary tile row at the top of the
  failures index showing counts by `failure_kind` (auth / runtime /
  deprovisioned_class / deleted_record).
- **`F-admin-failures-I2`** — Detail page should show related failures
  grouped by `fingerprint` (same underlying problem).
- **`F-admin-failures-I3`** — Detect "referenced record no longer
  exists" as a distinct `failure_kind=deleted_record` case, so retries
  can be short-circuited. The failure at id 212 is a good example: the
  post it references is gone and no retry will ever succeed.

### Optional

- **`F-admin-failures-O1`** — JSON console error on page load; same
  Tabulator fix as other index pages.

## Proposed fixes

### Will land in this branch

- Introduce `failure_kind: "deleted_record"` classification in
  `ApplicationJob` around-hook when rescue captures
  `ActiveRecord::RecordNotFound` tied to the job arguments. Mark
  `retryable=false` automatically.
- Render the by-kind summary tile on the failures index.
- Add "Related failures" block to the detail page
  (`BackgroundJobFailure.where(fingerprint: @failure.fingerprint)
  .order(created_at: :desc).limit(20)`).

### Deferred

- Tabulator console-error fix is shared with other index pages; will
  land once.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshots captured
