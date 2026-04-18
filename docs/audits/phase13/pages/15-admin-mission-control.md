# Admin Mission Control — `/admin/jobs`

## Snapshot

- **URL:** `/admin/jobs` (mounts `MissionControl::Jobs::Engine`)
- **Screenshot (before):** `../screenshots/before/15-admin-mission-control.png`
- **Captured at:** 2026-04-18 10:22 UTC
- **State:** 20+ Sidekiq queues, all showing `Pending jobs = 0`.
  Top nav shows **"Failed jobs (30)"**.

## Clarity of content

- Default Mission Control UI — terse but functional. "Back to main app"
  nav link is clear.

## UI / UX consistency

- Mission Control is an out-of-app engine so it doesn't use the
  sidebar/topbar styling. Acceptable — it's an operator tool linked
  from the Ops sidebar.

## Missing or redundant elements

- The long queue list includes several queues that are configured but
  never receive work (e.g. `home_story_sync`, `profile_reevaluation`,
  `story_auto_reply_orchestration` all at 0). Leftover from previous
  migrations?

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Any queue row link | click | drill into queue detail | Phase 2 ✅ |
| "Failed jobs (30)" | click | navigate to Mission Control failed-jobs list | Phase 2 ✅ |
| "Back to main app" | click | return to `/` | Phase 2 ✅ |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| Any Mission Control "Clear queue" / "Retry" / "Discard" action | operates on live Sidekiq state, not reversed easily |

## Background jobs triggered

- None.

## LLM calls observed

- None.

## Data / storage validation

- Failed jobs count **30** (Mission Control's `Failed jobs (30)` top
  nav). Compared to `BackgroundJobFailure.count = 196` — the two
  counts are **different**: Mission Control only sees what's in the
  Sidekiq dead set, while `BackgroundJobFailure` persists to our DB.
  This divergence is expected architecturally but worth documenting.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-mission-control-I1`** — Several always-empty queues look like
  leftover configuration from pre-migration phases. Candidate for
  removal from `config/sidekiq.yml` once verified with a code search
  (any job class that uses them). This is a cleanup, not a regression.
- **`F-mission-control-I2`** — Mission Control's failed-jobs count (30)
  does not match the app-level `BackgroundJobFailure.count` (196). The
  Failures index already acknowledges this is an application-persisted
  view, but the divergence should be called out in the copy.

### Optional

- **`F-mission-control-O1`** — Mission Control link lives only under
  `/admin/jobs`; consider surfacing its "Failed jobs (N)" count on the
  main Jobs dashboard.

## Proposed fixes

### Will land in this branch

- Cross-reference `config/sidekiq.yml` queues against
  `Rails.application.eager_load!; ObjectSpace.each_object(Class)` for
  `< ApplicationJob` or `include Sidekiq::Job`. Remove queues no
  concrete job class targets. Each removal is a one-line YAML change
  with a paired spec.
- Add a copy line to the main Jobs dashboard clarifying the
  "Sidekiq dead set (30)" vs "App failures (196)" distinction.

### Deferred

- Promoting MC's failed count into the main dashboard — cosmetic
  improvement, not blocking.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
