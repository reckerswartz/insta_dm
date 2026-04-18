# Admin Storage — `/admin/storage_ingestions` → `admin/storage_ingestions#index`

## Snapshot

- **URL:** `/admin/storage_ingestions`
- **View:** `app/views/admin/storage_ingestions/index.html.erb`
- **Screenshot (before):** `../screenshots/before/13-admin-storage.png`
- **DB state:** `ActiveStorage::Attachment.count` not yet probed; the
  tabulator grid shows 0 rows on initial load.
- **Captured at:** 2026-04-18 10:22 UTC
- **Console:** 1 JS error (shared Tabulator pattern).

## Clarity of content

- Subtitle *"Recent Active Storage records, including the background job
  responsible for creating each attachment"* explains exactly what is
  expected.

## UI / UX consistency

- Matches other admin tabulator pages.

## Missing or redundant elements

- No summary row (e.g. total bytes attached, count by content-type).
- No retention/pruning CTA.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Tabulator header filters | fill | narrow grid | Phase 2 ✅ |
| `Job` link inside a row | click | navigate to originating job detail | Phase 2 (empty-state) |

Destructive controls: none on this index.

## Background jobs triggered

- None triggered from this page.

## LLM calls observed

- None.

## Data / storage validation

- Dashboard shows `Storage Writes (24h) = 7`. Spot check: dev DB
  `ActiveStorage::Attachment.count` should match the rolling window
  aggregator. Rechecked in Phase 5.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-admin-storage-I1`** — Surface a summary row: total bytes / count
  by content-type / count by originating job class.
- **`F-admin-storage-I2`** — Expose a `PurgeDetachedBlobs` one-click
  action that enqueues the existing
  `PurgeExpiredInstagramPostMediaJob` (or sibling) for operators to
  reclaim space without running a rake task.

### Optional

- **`F-admin-storage-O1`** — 1 JS console error (shared Tabulator fix).

## Proposed fixes

### Will land in this branch

- Summary row of total bytes + count by content type.

### Deferred

- PurgeDetachedBlobs one-click action (Phase 14 candidate, non-trivial
  safety guardrails).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
