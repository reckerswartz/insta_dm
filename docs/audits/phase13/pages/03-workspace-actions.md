# Workspace Actions — `/workspace/actions` → `workspaces#actions`

## Snapshot

- **URL:** `/workspace/actions`
- **View:** `app/views/workspaces/actions.html.erb` +
  `_actions_queue_section.html.erb`.
- **Screenshot (before):** `../screenshots/before/03-workspace-actions.png`
- **DB state:** Queue empty; live update channel inactive (turbo-stream
  subscription present, no data).
- **Captured at:** 2026-04-18 10:19 UTC

## Clarity of content

- Page explicitly advertises scope: *“Stories and page-like profiles
  are excluded.”* Good — resolves a common operator confusion.
- “Queue order:” paragraph describes the tie-break rule set clearly.
- Empty-state copy (*“No user-post action items are pending. New captured
  posts will appear here automatically.”*) is present and on-brand.

## UI / UX consistency

- Counter bar `Total: 0 | Ready: 0 | Processing: 0 | Queued: 0 |
  Partial: 0 | Failed: 0 | Avg progress: 0% | Enqueued now: 0 | Updated
  less than a minute ago` is good, but the `Avg progress: 0%` with
  Total=0 is mathematically a divide-by-zero; surface `—` instead of
  `0%` when there's no sample to avoid a misleading signal.
- “Refresh” button without a loading spinner; relies on the *Refreshing
  queue…* inline text.

## Missing or redundant elements

- No link to filter by account when multi-account setups exist (today
  just the selected account).

## Interactive elements tested

| Control | Action | Expected | Status |
|---|---|---|---|
| `Refresh` | click | re-renders queue | ✅ empty state, no error |
| `Account Dashboard` link | click | `/instagram_accounts/:id` | ✅ |
| Turbo-stream subscription | live | updates when queue rows appear | deferred (no data) |

Destructive controls: none on this page.

## Background jobs triggered

- None — workspace-actions is a read-only queue view.

## LLM calls observed

- None.

## Data / storage validation

- Backed by `WorkspaceActionItem` (or equivalent) aggregate; with 0 rows
  we only confirm the controller renders without N+1 issues. Recheck in
  Phase 5 with synthetic rows.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-workspace-actions-I1`** — `Avg progress: 0%` is shown even when
  Total=0 (no sample). Replace with `—` or hide the metric when the
  denominator is zero.
  Source: `app/views/workspaces/_actions_queue_section.html.erb` and
  `app/services/workspace_actions/summary.rb`.

### Optional

- **`F-workspace-actions-O1`** — Consider collapsing the "Queue order"
  paragraph into an `<details>` to reduce top-of-page noise for repeat
  operators.

## Proposed fixes

### Will land in this branch

- Hide or re-label the `Avg progress` pill when Total=0.
- Tighten the Stimulus refresh controller to show a loading spinner
  while the `Refresh` fetch is in flight.

### Deferred

- Multi-account queue filter (Phase 14 candidate once > 1 account exists).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
