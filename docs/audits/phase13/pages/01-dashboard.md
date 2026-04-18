# Dashboard — `/` → `instagram_accounts#index`

## Snapshot

- **URL:** `/` (root), resolves to `instagram_accounts#index`
  (`app/views/instagram_accounts/index.html.erb`)
- **Screenshot (before):** `../screenshots/before/01-dashboard.png`
- **Account context:** `reckerswartz` (id=2)
- **DB state:** 1 account, 2 profiles, 0 posts, 196 `BackgroundJobFailure`,
  15 `AppIssue`, 0 messages, 0 feed posts
- **Captured at:** 2026-04-18 10:17 UTC

## Clarity of content

- Top-level intent (“Manage account health, sync workload, and daily AI
  throughput”) is clear.
- **“System Snapshot” card is alarming on first load**: `24h Failures = 196`
  and `24h Auth Failures = 75` are both dominated by a deleted job
  class (see finding `F-dashboard-C1`). First impression is that the app
  is broken, when the numbers reflect stale Sidekiq payloads.
- “Top Operations (24h): `health_check = 18` — 18 failed” is confusing;
  the user has no way to tell from this label that it corresponds to the
  NVIDIA health polls.

## UI / UX consistency

- “Profiles”, “Feed Posts”, “Jobs Console”, “Failure Logs”, “Issues”,
  “Storage”, “Feed Posts” buttons/links on the dashboard **exactly
  duplicate** the sidebar nav targets (finding `F-dashboard-I1`). Either
  merge into a tighter CTA strip or drop them.
- “Add Account” is correctly emphasised as a primary button.
- Queue card shows `Avg wait (ms) = 87070.7` (~87 s) because stale
  samples dominate — this is the same root cause as the
  `CheckLocalAiHealthJob` problem.

## Missing or redundant elements

- **Empty-state hint missing for follower graph**: nothing on the
  dashboard nudges the operator to click
  *Sync Followers/Following* when the DB has zero followers and zero
  following. The account-show page has a prominent first-run hint;
  the dashboard does not.

## Interactive elements tested

| Control | Action | Expected | Actual | Status |
|---|---|---|---|---|
| Sidebar → Dashboard/Actions Queue/Profiles/Feed Posts/AI Services/Jobs/Failures/Issues/Storage | click | navigate to route | verified in later walks | ✅ |
| Quick-nav Workspace / Profiles / Posts / Jobs | click | duplicate sidebar targets | redundant | ⚠️ |
| Topbar `reckerswartz` account link | click | `/instagram_accounts/2` | verified | ✅ |
| `Add Account` button | click | opens modal (not fired) | inventory only | inventory |
| Row `Select` button | click | `POST /instagram_accounts/:id/select` | not fired in Phase 2 | inventory |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| Row `Delete` button | Destroys the only InstagramAccount in the dev DB |

## Background jobs triggered

- None fired from this page during Phase 1.

## LLM calls observed

- None on this page.

## Data / storage validation

- `InstagramAccount.count = 1`, `InstagramProfile.count = 2`,
  `BackgroundJobFailure.count = 196`, `AppIssue.count = 15`.
- The rendered `24h Failures = 196` equals the raw `BackgroundJobFailure`
  table count — there's no 24h windowing filter being applied on this
  surface.

## Findings

### Critical

- **`F-dashboard-C1`** — Dashboard aggregate counters
  (`24h Failures=196`, `24h Auth Failures=75`, `Top Ops: health_check=18
  failed`, `Avg wait=87 s`) are poisoned by stale Sidekiq payloads for
  the deleted `CheckLocalAiHealthJob` class (Phase 10 removed it; Redis
  still holds enqueued references → Sidekiq throws
  `ActiveJob::UnknownJobClassError` and the error-handler itself blows
  up with `NameError: uninitialized constant CheckLocalAiHealthJob`).
  Confirmed live in `log/development.log` at 2026-04-18T10:22:10Z.
  Source: `app/views/instagram_accounts/index.html.erb`,
  `app/services/ops/*_snapshot.rb` (24h aggregators).

### Improvement

- **`F-dashboard-I1`** — In-main-body button strip (“Profiles”,
  “Feed Posts”, Jobs Console, Failure Logs, Issues, Storage, Feed Posts)
  duplicates every single sidebar target. Either compress into a tighter
  CTA or remove.
  Source: `app/views/instagram_accounts/index.html.erb`.
- **`F-dashboard-I2`** — Dashboard does not surface the first-run hint
  the account-show page does when `followers=0 && following=0`. Mirror
  the hint up here for operators who land on `/` directly.

### Optional

- **`F-dashboard-O1`** — “Feed Posts” is listed twice in the
  dashboard-body link strip.

## Proposed fixes

### Will land in this branch (Phase 7)

- Implement a scheduled `PurgeOrphanedSidekiqJobsJob` + a one-shot rake
  task to drain queued/retrying jobs whose `job_class` is no longer
  resolvable by `ActiveJob::Base.lookup`. Emit a `BackgroundJobFailure`
  with `failure_kind=deprovisioned_class` so the dashboard can tag them
  out of the 24h window rather than silently retrying forever.
- Add `provider=local_ai_stack` / `job_class=CheckLocalAiHealthJob`
  exclusion filter in the Ops snapshot services behind a feature flag
  so newly-deployed stale payloads don't poison future counters.
- Remove duplicate “Feed Posts” link and compress the in-body button
  strip on the dashboard.
- Echo the account-show first-run follower hint on the dashboard when
  the current account has zero followers and zero following.

### Deferred

- None.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed (commits: ...)
- [ ] Re-walk screenshot captured
