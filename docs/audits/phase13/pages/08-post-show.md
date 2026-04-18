# Post Show (missing record) — `/instagram_posts/:id`

## Snapshot

- **URL:** `/instagram_posts/1`
- **Controller action:** `app/controllers/instagram_posts_controller.rb#show`
  (line 44: `@post = @account.instagram_posts.find(params[:id])`).
- **Screenshot (before):** `../screenshots/before/08-post-show-missing.png`
- **DB state:** `InstagramPost.count = 0` — no record with id=1.
- **Observed:** Raw Rails exception page
  (`ActiveRecord::RecordNotFound`). In production this would be a 500.
- **Captured at:** 2026-04-18 10:21 UTC

## Clarity of content

- Same issue as `F-story-people-show-C1`: no `rescue_from` in the
  controller, so a missing id bubbles up to a 500 in production.

## UI / UX consistency

- Error page breaks layout (out-of-band Rails debug template).

## Missing or redundant elements

- No fallback to `/instagram_posts` with a flash message.

## Interactive elements tested

- N/A.

## Background jobs triggered

- None.

## LLM calls observed

- None.

## Data / storage validation

- `InstagramPost.count = 0` confirms the resource doesn't exist.

## Findings

### Critical

- **`F-post-show-C1`** — `/instagram_posts/1` raises
  `ActiveRecord::RecordNotFound` that escapes the controller and
  becomes a 500 in production. Fix alongside `F-story-people-show-C1`.
  Source: `app/controllers/instagram_posts_controller.rb:44`.

### Improvement

- None page-local beyond the shared 404 fix.

### Optional

- None.

## Proposed fixes

### Will land in this branch

- Covered by the shared `ApplicationController#rescue_from
  ActiveRecord::RecordNotFound` landing fix.

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured (verify 404 page, not 500)
