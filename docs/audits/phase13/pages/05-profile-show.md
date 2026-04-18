# Profile Show — `/instagram_profiles/:id` → `instagram_profiles#show`

## Snapshot

- **URL:** `/instagram_profiles/2`
- **View:** `app/views/instagram_profiles/show.html.erb` plus sections:
  `_action_history_section`, `_captured_posts_section`,
  `_downloaded_stories_section`, `_events_table_section`,
  `_messages_section`, `_profile_tags_section`.
- **Screenshot (before):** `../screenshots/before/05-profile-show.png`
- **DB state:** Profile `reckerswartz` (id=2, `instagram_account_id=2`),
  9 captured posts, 0 analyzed posts, 141 action logs, last analysed
  ~4 hours ago.
- **Captured at:** 2026-04-18 10:20 UTC

## Clarity of content

- Header with username + status list (Following/Follows you/Mutual/
  Can message/Last active/History) is an effective elevator pitch.
- `Current Status` card's three sub-boxes
  (Relationship / Activity / Content Readiness) are clean and
  information-dense.
- `At a Glance` panel below duplicates three of the Content Readiness
  fields — see `F-profile-show-I1`.

## UI / UX consistency

- In-page `Profile sections` nav (Overview / Details / Build History /
  Mutual / AI / Posts / Stories / Messages / Actions / History) is useful
  for this long page.
- The `Engagement policy: Eligible` row that landed with Phase 11 works
  and the hint text is clear.

## Missing or redundant elements

- `Pending analysis = 9` surfaces both in `Content Readiness` and
  `At a Glance` — redundant. Could be collapsed to a single block.
- Analysis state shows `AI analyzed = 0` with 9 pending; no obvious
  CTA on this page to trigger the batch analyze. The control lives at
  the `/instagram_profiles/:id/instagram_profile_posts/analyze_next_batch`
  route but is not exposed as a button on this page.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| `Capture Posts` | click | enqueues profile-post-capture job | Phase 3 candidate |
| `Fetch Details` | click | refreshes profile metadata | Phase 3 candidate |
| Profile section anchor links | click | scroll/focus to fragment | Phase 2 ✅ |
| `Save Tags` (after ticking `friend` or similar) | submit | `PATCH tags` → re-render policy pill | Phase 2 ✅ |
| `Maintenance actions` / `Story analysis actions` `<details>` | click | expand subpanels | Phase 2 ✅ |
| `download` (avatar blob) | click | Active Storage redirect | inventory |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| `Mark Incorrect` / `Separate Face` in any nested story person | writes to `InstagramStoryPerson` state |
| Verify messageability | fires live Instagram browser check |

## Background jobs triggered

- Deferred to Phase 3.

## LLM calls observed

- Deferred to Phase 4; the `AI` anchor expands an analysis subpanel that
  references `Ai::VlmPeopleSummaryService` and `Ai::Runner`.

## Data / storage validation

- Spot-check confirms `InstagramProfile(id=2).instagram_profile_posts.count = 9`.
- `AiAnalysis.where(purpose: "profile").where(instagram_profile_id: 2).count`
  should equal the `analyzed posts` figure; recheck in Phase 5.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-profile-show-I1`** — Duplicate `Pending analysis = 9` block.
  Collapse `Current Status > Content Readiness` and `At a Glance > Posts
  (Image Input)` into a single card to reduce cognitive load.
- **`F-profile-show-I2`** — Surface `Analyze next batch` as a button on
  the profile show page instead of being only callable through
  `/instagram_profile_posts/analyze_next_batch`.
- **`F-profile-show-I3`** — "History: Building" is displayed without a
  progress indicator or ETA. The `Build History` section below has
  copy about "re-checks face identity mapping" — now legacy (Phase 12
  removed that path). Update copy to match the current pipeline.

### Optional

- **`F-profile-show-O1`** — Profile status chip list at top ~ duplicates
  the `Current Status > Relationship` card. Keep one.

## Proposed fixes

### Will land in this branch

- Update `_captured_posts_section.html.erb` / At-a-Glance partial to
  share a single summary. Remove duplicated `Pending analysis`.
- Add an `Analyze next 5 posts` button that POSTs to
  `analyze_next_batch`.
- Rewrite `Build History` copy to reflect the post-Phase-12 pipeline
  (drop face identity references).

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
