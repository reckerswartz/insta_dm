# Story People Show (missing record) — `/instagram_profiles/:id/people/:person_id`

## Snapshot

- **URL:** `/instagram_profiles/2/people/1`
- **Controller action:**
  `app/controllers/instagram_story_people_controller.rb#show`
  (set_person sets `@profile.instagram_story_people.find(params[:id])`)
- **Screenshot (before):** `../screenshots/before/06-story-people-show-404.png`
- **DB state:** `InstagramStoryPerson.count = 0` — the record does not exist.
- **Observed:** Rails returns **500 Internal Server Error** with the
  default development error page
  (`ActiveRecord::RecordNotFound: Couldn't find InstagramStoryPerson
  with 'id'="1"`).
- **Captured at:** 2026-04-18 10:20 UTC

## Clarity of content

- In development the raw Rails error page is shown. In production the
  default is a generic 500 — not a 404, and not the styled app layout.
- An operator who mis-clicks a stale link gets a scary "exception" page
  with parameters and source code. This leaks context and breaks the
  sidebar/layout entirely.

## UI / UX consistency

- The error page is out-of-band and therefore breaks layout consistency
  by design. That's the Rails default — the app is just failing to
  rescue.

## Missing or redundant elements

- No `rescue_from ActiveRecord::RecordNotFound` in
  `InstagramStoryPeopleController` (or a parent). The result: server
  returns 500 (in dev this renders the debug page) instead of a
  user-friendly 404.
- Upstream links to story-people records should treat a missing record
  as a deleted/merged-person case and point the operator back to the
  owning profile.

## Interactive elements tested

- N/A — no actionable controls on the raw error page.

## Background jobs triggered

- None.

## LLM calls observed

- None.

## Data / storage validation

- Confirmed `InstagramStoryPerson.count = 0` in the dev DB. Any valid
  link to this page would have been formed by the
  `instagram_story_people#index` listing, which currently has nothing
  to list. The 500 is reached via a stale/forged URL.

## Findings

### Critical

- **`F-story-people-show-C1`** — `/instagram_profiles/2/people/1` raises
  `ActiveRecord::RecordNotFound` which escapes the controller and
  becomes a **500 in production**. Three controllers share this pattern
  (see also `F-post-show-C1` for the feed-post equivalent).
  Source: `app/controllers/instagram_story_people_controller.rb:80`.

### Improvement

- **`F-story-people-show-I1`** — No breadcrumb back to the owning
  profile; even a polished 404 should send the operator back to
  `/instagram_profiles/:id`.

### Optional

- None.

## Proposed fixes

### Will land in this branch

- Introduce a shared
  `ApplicationController#rescue_from ActiveRecord::RecordNotFound` that
  renders `shared/not_found` with a breadcrumb back to the most relevant
  parent (instagram profile / instagram account / home). Add a regression
  spec under `spec/requests/` that asserts a 404 + styled layout is
  returned for a missing story-person id.

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured (verify 404 styled page replaces raw error)
