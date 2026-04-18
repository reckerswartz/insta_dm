# Profiles Index — `/instagram_profiles` → `instagram_profiles#index`

## Snapshot

- **URL:** `/instagram_profiles`
- **View:** `app/views/instagram_profiles/index.html.erb`
- **Screenshot (before):** `../screenshots/before/04-profiles-index.png`
- **DB state:** 2 profiles in the DB but the Tabulator grid shows
  `0 rows` (see finding `F-profiles-index-C1`).
- **Captured at:** 2026-04-18 10:20 UTC
- **Console error:** 1 JS error logged (details in
  `.playwright-mcp/console-2026-04-18T10-20-19-896Z.log`).

## Clarity of content

- Heading / subhead *"Browse profiles for reckerswartz"* is clear.
- Sync block explicitly calls out that Followers+Following is the
  primary source — this is the right framing.

## UI / UX consistency

- Tabulator header controls match other admin tables (failures, issues,
  storage).

## Missing or redundant elements

- **The Tabulator grid loads `0 rows` even though `InstagramProfile.count = 2`.**
  This is the *current account's* profile scope that contains
  `reckerswartz` (id=2) itself, which is typically filtered out as
  "the account's own mirror". But the sync summary at the top of the
  page says *"Profiles: 2"* — the two numbers contradict each other on
  the same page. See `F-profiles-index-C1`.
- Avatar column has no placeholder icon specified when a profile lacks
  an attached avatar blob.

## Interactive elements tested

| Control | Action | Expected | Status |
|---|---|---|---|
| `Sync Followers/Following (Background)` | click | enqueues follow-graph sync | Phase 3 candidate |
| `Download Missing Avatars (Background)` | click | enqueues avatar sync | inventory |
| Tabulator column header filters / sorts | type/click | filter the grid | empty state |
| `Account Dashboard` link | click | `/instagram_accounts/:id` | ✅ |

## Background jobs triggered

- Deferred to Phase 3.

## LLM calls observed

- None.

## Data / storage validation

- `InstagramProfile.count = 2` but the index grid shows 0 because the
  index controller filters out profiles flagged as "self mirror" or
  missing `is_followers_or_following`. The page needs to reconcile the
  summary strip ("Profiles: 2") with the grid ("0 rows"). Worth a
  controller comment + test.

## Findings

### Critical

- **`F-profiles-index-C1`** — Summary strip shows `Profiles: 2` while
  the Tabulator grid shows `0 rows`; same page, same account, different
  services. Data-contract mismatch between the top summary and the
  table's JSON payload.
  Source: `app/controllers/instagram_profiles_controller.rb#index`,
  `app/services/instagram_profiles/index_query.rb`.

### Improvement

- **`F-profiles-index-I1`** — 1 JS console error on page load. Needs
  isolation; likely a Tabulator column definition referencing a
  missing data accessor for 0-row state.
- **`F-profiles-index-I2`** — No placeholder avatar when the profile
  has no attached blob. Use the neutral `/icon.svg` or initials.

### Optional

- None.

## Proposed fixes

### Will land in this branch

- Make the summary strip consume the same query object the Tabulator
  JSON endpoint uses, so the numbers can never disagree. One place to
  count, one place to filter.
- Triage the console error; add a Tabulator formatter that returns
  a neutral placeholder when `row.avatar_url` is nil.

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
