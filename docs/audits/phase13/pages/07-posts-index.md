# Posts Index — `/instagram_posts` → `instagram_posts#index`

## Snapshot

- **URL:** `/instagram_posts`
- **View:** `app/views/instagram_posts/index.html.erb`
- **Screenshot (before):** `../screenshots/before/07-posts-index.png`
- **DB state:** `InstagramPost.count = 0`. Autonomous capture mode =
  `Enabled`.
- **Captured at:** 2026-04-18 10:21 UTC
- **Console:** 1 JS error logged (same Tabulator empty-state issue as
  profiles index).

## Clarity of content

- Page purpose is clear (*"Captured from your home feed during feed
  capture runs"*).
- "Autonomous mode: Enabled | Next automated feed capture: Pending next
  continuous-processing cycle" is a good status line, but "Pending next
  continuous-processing cycle" is vague — no concrete ETA even though
  we know
  `continuous_processing_next_feed_sync_at` is being computed elsewhere.

## UI / UX consistency

- Matches the Profiles index layout (action strip + Sync block + Data
  table). Good.

## Missing or redundant elements

- `Feed Capture Activity` says *"No feed capture activity recorded yet"*
  but the sidebar dashboard's `Top Operations (24h)` card shows
  `health_check = 18`. That means log records are being written somewhere
  that this page is not reading from. Inconsistency worth
  investigating in Phase 5.

## Interactive elements tested

| Control | Action | Expected | Status |
|---|---|---|---|
| `Capture Feed (Background)` | click | `POST /feed_capture` enqueues `CaptureHomeFeedJob` | Phase 3 candidate |
| `Account Dashboard` link | click | `/instagram_accounts/2` | ✅ |
| Tabulator header filters | fill | filter posts grid | empty state |

## Background jobs triggered

- Deferred to Phase 3.

## LLM calls observed

- None on this page.

## Data / storage validation

- With `InstagramPost.count = 0` the Tabulator `/instagram_posts.json`
  endpoint should return `rows: []`. Spot-check in Phase 5.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-posts-index-I1`** — "Next automated feed capture: Pending next
  continuous-processing cycle" should show the resolved
  `continuous_processing_next_feed_sync_at` timestamp instead of
  opaque copy.
  Source: `app/views/instagram_accounts/_feed_capture_activity_section.html.erb`
  (used by the posts index via shared partial).
- **`F-posts-index-I2`** — 1 JS console error on page load. Same pattern
  as `F-profiles-index-I1`.

### Optional

- **`F-posts-index-O1`** — Page title in topbar says "Feed Posts", page
  heading in main content says "Feed Posts", and sidebar label also
  says "Feed Posts" — not a bug, just a lot of repetition.

## Proposed fixes

### Will land in this branch

- Resolve the `continuous_processing_next_feed_sync_at` timestamp and
  render as `in 12 minutes (2026-04-18 10:33 UTC)`.
- Fix the Tabulator console error (shared fix with profiles index).

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
