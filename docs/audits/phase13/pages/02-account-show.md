# Account Show — `/instagram_accounts/:id` → `instagram_accounts#show`

## Snapshot

- **URL:** `/instagram_accounts/2`
- **View:** `app/views/instagram_accounts/show.html.erb` plus 6 partials:
  `_account_health_auth_section`, `_actions_to_be_done_section`,
  `_audit_logs_section`, `_feed_capture_activity_section`,
  `_skip_diagnostics_section`, `_story_archive_refresh_signal`.
- **Screenshot (before):** `../screenshots/before/02-account-show.png`
- **Account context:** `reckerswartz` (id=2), authenticated cookie
  `sessionid` present.
- **Captured at:** 2026-04-18 10:19 UTC

## Clarity of content

- Heading + *Login state / Last sync* strip immediately conveys health.
- `Current Status` card split into *Authentication / Latest Sync /
  Workspace Queue* is good.
- **First-run hint surfaces correctly** (“No followed / follower profiles
  have been synced yet…”). This is already the fix the Phase 11 smoke walk
  recommended; it is present here but missing from the dashboard
  (cf. `F-dashboard-I2`).
- `Work (24h)` card shows `Failures = 174` — same poison source as the
  dashboard aggregates (`CheckLocalAiHealthJob`).

## UI / UX consistency

- Sidebar + topbar render identically to other pages.
- The lower action blocks ("Advanced workload actions", "Authentication
  System", "Maintenance actions") collapse nicely via `<details>`.
- Buttons mix capitalisation: `Sync Followers/Following (Background)`,
  `Sync Next 10 Stories`, `Run Continuous Processing Now`,
  `Download Missing Avatars (Background)`, `Select This Account`.
  Consistency-wise the `(Background)` suffix is only on two of the four.

## Missing or redundant elements

- `Downloaded Story Archive` card shows filters + Refresh button even
  though the archive is “idle” (archive has to be loaded first). Filters
  should be disabled until the archive has loaded at least one page.
- `AI API Usage (24h)` cell shows `Total calls = 0` while the top
  `Work (24h) Failures = 174` and AI Analyses `succeeded = 12` are
  non-zero — misleading.

## Interactive elements tested

| Control | Action | Expected | Phase | Notes |
|---|---|---|---|---|
| `Sync Followers/Following (Background)` | click | enqueues `EnqueueFollowGraphSyncForAccountJob` | Phase 3 trigger target | |
| `Download Missing Avatars (Background)` | click | enqueues `EnqueueAvatarSyncForAccountJob` | inventory | |
| `Sync Next 10 Stories` | click | enqueues `SyncInstagramAccountStoriesJob` | Phase 3 candidate | |
| `Run Continuous Processing Now` | click | enqueues `ProcessInstagramAccountContinuouslyJob` | Phase 3 candidate | |
| `Select This Account` | click | `POST :select` + session cookie update | inventory | |
| Archive `Date filter`, `LLM status`, `Failure reason code` | fill | filter archive feed | Phase 2 | empty-state |
| `Refresh` | click | reloads archive chunk | Phase 2 | empty-state |
| Various collapsed `<details>` toggles | click | show/hide | Phase 2 | |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| `Import Cookies` (inside Authentication System panel) | overwrites the live `sessionid`, risks logging the account out |
| `Manual Login` | fires a Playwright Chromium session, can collide with MCP sidecar |
| `Validate Session` | issues a live Instagram probe |
| Any delete/destroy inside `technical_details` | irreversible |

## Background jobs triggered

Fired in Phase 3 (see `phase-notes/03-jobs.md`). Suggestion matrix:

| Button | Job | Queue | Expected side-effect |
|---|---|---|---|
| Sync Followers/Following | `EnqueueFollowGraphSyncForAccountJob` | sync | populates `InstagramProfile` rows |
| Run Continuous Processing Now | `ProcessInstagramAccountContinuouslyJob` | profiles | cascades feed capture + story sync |
| Sync Next 10 Stories | `SyncInstagramAccountStoriesJob` | sync | populates story archive |

## LLM calls observed

- “Generate LLM comment” button lives under an action subpanel. Exercised
  in Phase 4 (`phase-notes/04-llm.md`).

## Data / storage validation

- `Account Totals: Profiles=2 / Followers=0 / Following=0 / Messages=0 /
  Feed posts=0` confirms the dev DB sparseness.
- `Action logs = 141` despite messages=0 — so the `AppActionLog` table is
  being populated by synthetic events.

## Findings

### Critical

- *(none page-local; `F-dashboard-C1` covers the 24h counter poisoning
  which also manifests on this page’s `Work (24h) Failures=174`.)*

### Improvement

- **`F-account-show-I1`** — Inconsistent `(Background)` suffix on sync
  buttons. Every sync/download button should carry the same suffix.
  Source: `app/views/instagram_accounts/show.html.erb` and the two Sync
  partials.
- **`F-account-show-I2`** — `Downloaded Story Archive` filter controls
  are enabled even before the archive has loaded. Gate them on the
  archive’s `loaded` signal.
  Source: `app/views/instagram_accounts/_story_archive_refresh_signal.html.erb`.
- **`F-account-show-I3`** — `AI API Usage (24h): Total=0` contradicts the
  `Work (24h): Failures=174` and `AI Analyses succeeded=12` that sit on
  the same page. Normalise the 24h aggregator so rows refer to the same
  window and provider definition.

### Optional

- **`F-account-show-O1`** — Consider promoting the first-run hint from
  the Sync & Workload section into a dismissible topbar banner; it's
  easy to scroll past in its current position.

## Proposed fixes

### Will land in this branch (Phase 7)

- Normalise copy: append `(Background)` to every action that returns
  202-and-enqueues. Short helper `view_background_action_button(label)`
  in `app/helpers/instagram_accounts_helper.rb`.
- Extract `Downloaded Story Archive` filter block into a Stimulus
  controller that disables filter inputs while `data-archive-loaded=false`.
- Unify the 24h aggregator contract (see `F-dashboard-C1` fix) so all
  three surfaces share one service object.

### Deferred

- Promotion of the first-run hint into a topbar banner pending broader
  first-run UX pass (Phase 14 candidate).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
