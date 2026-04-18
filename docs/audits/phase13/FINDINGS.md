# Phase 13 — Consolidated findings

> Aggregated from the per-page files under `pages/` and the phase notes.
> Sorted: **Critical → Improvement → Optional**. Status transitions
> `open → fixed | follow-up | accepted`. Commit column filled in as
> Phase 7 work lands.

## Critical

| Finding ID | Page | Summary | Source | Proposed fix | Status | Commit |
|---|---|---|---|---|---|---|
| `F-dashboard-C1` | 01 dashboard | `24h Failures=196`, `Top Ops: health_check=18` poisoned by 29 stale `CheckLocalAiHealthJob` retry payloads (class deleted in Phase 10 but still enqueued; `ActiveJob::UnknownJobClassError` fires on every retry, then error-handler itself raises `NameError`). Confirmed live in `log/development.log` 2026-04-18T10:22:10Z. | `app/views/instagram_accounts/index.html.erb`, `Ops::*Snapshot`, Sidekiq retry set. | Sidekiq server middleware that classifies `UnknownJobClassError` as `deprovisioned_class` + purge rake + exclude from 24h aggregator | open | |
| `F-admin-background-jobs-C1` | 10 admin-background-jobs | Same root cause as `F-dashboard-C1`: the stale-class retry loop is not surfaced anywhere. `Jobs::FailureRetry` cannot classify the class; `Ops::IssueTracker` can't emit an `AppIssue` because fingerprint relies on resolving the class. | `app/jobs/application_job.rb`, `app/services/ops/issue_tracker.rb`. | Shared fix with `F-dashboard-C1` + "Deprovisioned job class" banner on the dashboard | open | |
| `F-story-people-show-C1` | 06 story-people-show | `/instagram_profiles/:id/people/:person_id` with missing id raises `ActiveRecord::RecordNotFound` → 500 in production (styled exception page in dev). No `rescue_from` in controller. | `app/controllers/instagram_story_people_controller.rb:80`. | `ApplicationController#rescue_from ActiveRecord::RecordNotFound` → `shared/not_found` with breadcrumb | open | |
| `F-post-show-C1` | 08 post-show | Same pattern: `/instagram_posts/:id` with missing id 500s in production. | `app/controllers/instagram_posts_controller.rb:44`. | Shared fix with `F-story-people-show-C1` | open | |
| `F-profiles-index-C1` | 04 profiles-index | `Summary: Profiles=2` disagrees with grid `0 rows` on the same page. Two code paths, same account. Data-contract mismatch. | `app/controllers/instagram_profiles_controller.rb#index`, grid JSON endpoint. | Route both the summary strip and the Tabulator JSON payload through a single `InstagramProfiles::IndexQuery` service | open | |

## Improvement

| Finding ID | Page | Summary | Source | Proposed fix | Status | Commit |
|---|---|---|---|---|---|---|
| `F-dashboard-I1` | 01 dashboard | Dashboard in-body button strip duplicates every sidebar target; "Feed Posts" is listed twice. | `app/views/instagram_accounts/index.html.erb` | Compress / deduplicate | open | |
| `F-dashboard-I2` | 01 dashboard | Dashboard does not surface the first-run follower hint (account-show page does). | Dashboard partial | Echo hint when `account.followers.count == 0 && account.following.count == 0` | open | |
| `F-account-show-I1` | 02 account-show | Inconsistent `(Background)` suffix on sync/download buttons. | `app/views/instagram_accounts/show.html.erb` + Sync partials | `view_background_action_button(label)` helper | open | |
| `F-account-show-I2` | 02 account-show | Story-archive filters enabled before archive has loaded. | `_story_archive_refresh_signal` | Stimulus gate on `archive-loaded` flag | open | |
| `F-account-show-I3` | 02 account-show | AI API Usage (24h) Total=0 contradicts Work (24h) Failures=174 / AI Analyses succeeded=12 on same page. | 24h aggregators | Unify 24h service; same scope + window | open | |
| `F-workspace-actions-I1` | 03 workspace-actions | `Avg progress: 0%` with Total=0 (divide-by-zero signal). | `_actions_queue_section` + summary service | Show `—` when denominator zero | open | |
| `F-profile-show-I1` | 05 profile-show | `Pending analysis = 9` duplicated in two cards. | `app/views/instagram_profiles/show.html.erb` | Collapse | open | |
| `F-profile-show-I2` | 05 profile-show | `Analyze next batch` button missing on profile show. | Profile show view | Add button POSTing `instagram_profile_posts#analyze_next_batch` | open | |
| `F-profile-show-I3` | 05 profile-show | `Build History` copy references Phase-12-removed face identity mapping. | Profile show view | Update copy | open | |
| `F-story-people-show-I1` | 06 story-people-show | Even a polished 404 should include a breadcrumb back to the profile. | shared not_found partial | Inject breadcrumb context | open | |
| `F-posts-index-I1` | 07 posts-index | "Next automated feed capture: Pending next continuous-processing cycle" should resolve to the concrete timestamp. | feed capture partial | Resolve `continuous_processing_next_feed_sync_at` | open | |
| `F-posts-index-I2` | 07 posts-index | 1 JS console error on page load (Tabulator empty-row state). | posts index view | Formatter fix | open | |
| `F-ai-dashboard-I1` | 09 ai-dashboard | Subtitle promises "cleanup candidates" but the block doesn't render. | ai dashboard view | Add cleanup block or fix copy | open | |
| `F-ai-dashboard-I2` | 09 ai-dashboard | All lanes show ETA confidence `low` even with n≥10. | lane summary service | Adjust thresholds | open | |
| `F-ai-dashboard-I3` | 09 ai-dashboard | `Lightweight Controls` raw code flags without context. | ai dashboard view | Move to `<details>` with source-of-truth links | open | |
| `F-admin-background-jobs-I1` | 10 admin-background-jobs | Dashboard has no banner for the deprovisioned-class retry loop. | background jobs dashboard view | Banner + purge CTA | open | |
| `F-admin-failures-I1` | 11 admin-failures | No summary tile row by failure_kind. | failures index view | Add tile row | open | |
| `F-admin-failures-I2` | 11 admin-failures | Failure detail page doesn't group by fingerprint. | failure detail view | Related-failures block | open | |
| `F-admin-failures-I3` | 11 admin-failures | Need `failure_kind=deleted_record` classification. | `ApplicationJob` around-hook | Classify + retryable=false | open | |
| `F-admin-issues-I1` | 12 admin-issues | No severity tile row. | issues index view | Add tile row | open | |
| `F-admin-issues-I2` | 12 admin-issues | Issues don't link to matching failures by fingerprint. | issues payload builder | Include related_failure_count + link | open | |
| `F-admin-storage-I1` | 13 admin-storage | No summary row (bytes, count by content-type). | storage index view | Add summary row | open | |
| `F-admin-ai-provider-I1` | 14 admin-ai-provider | "Local provider (legacy)" section references a provider deleted in Phase 9. | ai provider settings view | Delete dead block | open | |
| `F-admin-ai-provider-I2` | 14 admin-ai-provider | `Test key` button lacks a loading indicator. | ai provider settings view | Stimulus + spinner | open | |
| `F-mission-control-I1` | 15 admin-mission-control | Always-empty queues in `config/sidekiq.yml`. | `config/sidekiq.yml` | Remove unused queues | open | |
| `F-mission-control-I2` | 15 admin-mission-control | MC "Failed jobs (30)" vs app-level `BackgroundJobFailure=196` divergence not explained. | admin failures copy | Add clarifying line | open | |
| `F-overlays-I1` | XX overlays | "Session Active" pill is a static string. | `layouts/application.html.erb` | Bind to `current_account.cookie_auth_valid?` | open | |
| `F-overlays-I2` | XX overlays | `/favicon.ico` 404s flood the dev log on every nav. | `public/` | Add `public/favicon.ico` | open | |
| `F-overlays-I3` | XX overlays | Flash alerts auto-close after 5 s for error variants. | `layouts/application.html.erb` inline JS | 15 s for alert/danger | open | |
| `F-profiles-index-I1` | 04 profiles-index | 1 JS console error on page load. | profiles index view | Tabulator formatter | open | |
| `F-profiles-index-I2` | 04 profiles-index | No avatar placeholder. | profiles index view | Placeholder formatter | open | |

## Optional

| Finding ID | Page | Summary | Source | Proposed fix | Status | Commit |
|---|---|---|---|---|---|---|
| `F-dashboard-O1` | 01 dashboard | "Feed Posts" listed twice. | dashboard view | Remove duplicate | open | |
| `F-workspace-actions-O1` | 03 workspace-actions | Collapse "Queue order" into `<details>`. | workspace actions view | Collapsible | open | |
| `F-account-show-O1` | 02 account-show | Promote first-run hint to topbar banner. | layout + account show | Cross-page promotion | open | |
| `F-profile-show-O1` | 05 profile-show | Header status chip list duplicates Relationship card. | profile show view | Keep one | open | |
| `F-posts-index-O1` | 07 posts-index | "Feed Posts" title repeated in topbar, heading, sidebar. | cosmetic | Keep one | open | |
| `F-ai-dashboard-O1` | 09 ai-dashboard | Available models list truncated. | ai dashboard view | Hover/click expand | open | |
| `F-admin-background-jobs-O1` | 10 admin-background-jobs | Dashboard could split into tabs. | dashboard refactor | Tabs | open | |
| `F-admin-failures-O1` | 11 admin-failures | JS console error (shared Tabulator fix). | failures view | Shared fix | open | |
| `F-admin-issues-O1` | 12 admin-issues | JS console error (shared Tabulator fix). | issues view | Shared fix | open | |
| `F-admin-storage-O1` | 13 admin-storage | JS console error (shared Tabulator fix). | storage view | Shared fix | open | |
| `F-admin-ai-provider-O1` | 14 admin-ai-provider | Group roles by purpose. | ai provider settings view | Reorder | open | |
| `F-mission-control-O1` | 15 admin-mission-control | Surface MC failed count on main dashboard. | cosmetic | Cross-link | open | |
| `F-overlays-O1` | XX overlays | Topbar Quick Nav duplicates sidebar. | cosmetic | Mobile-only | open | |

## Residual risk / follow-up for Phase 14

- Persistent `AnalyzeAiFeatureEvidenceJob` retry (1 payload in retry
  set, days=14). If the job class still exists, investigate why it's
  stuck (likely a transient failure). Not a blocker.
- Dashboard tab split (`F-admin-background-jobs-O1`) — deferred from
  Phase 13 scope.
- First-run topbar banner promotion (`F-account-show-O1`) — UX pass
  deferred.
- Bulk Active Storage purge CTA (`F-admin-storage-I2`) — needs safety
  guardrails.
