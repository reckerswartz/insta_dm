# Phase 13 — Application audit

> Branch: `feat/phase13-application-audit`. Driver: existing `@playwright/mcp`
> sidecar. Target: `http://localhost:3000` (current dev DB as-is). Output
> layout: one Markdown file per page under `pages/`, consolidated findings
> in `FINDINGS.md`, running notes in `phase-notes/`, before/after
> screenshots in `screenshots/`.

## Scope decisions (locked 2026-04-18)

| Decision | Choice |
|---|---|
| Playwright driver | Existing `@playwright/mcp` server (no new test suite checked in) |
| Data fixtures | Current dev DB as-is (empty-state findings are valid output) |
| Output layout | `docs/audits/phase13/pages/<slug>.md` + `FINDINGS.md` rollup |
| Implementation scope | Audit + full implementation of recommended fixes in this branch |

## Page inventory

Slugs match `pages/<slug>.md` and `screenshots/{before,after}/<slug>.png`.

| # | Slug | Route | Controller#action | View |
|---|---|---|---|---|
| 01 | `dashboard` | `/` → `/instagram_accounts` | `instagram_accounts#index` | `app/views/instagram_accounts/index.html.erb` |
| 02 | `account-show` | `/instagram_accounts/:id` | `instagram_accounts#show` | `app/views/instagram_accounts/show.html.erb` (+6 partials) |
| 03 | `workspace-actions` | `/workspace/actions` | `workspaces#actions` | `app/views/workspaces/actions.html.erb` |
| 04 | `profiles-index` | `/instagram_profiles` | `instagram_profiles#index` | `app/views/instagram_profiles/index.html.erb` |
| 05 | `profile-show` | `/instagram_profiles/:id` | `instagram_profiles#show` | `app/views/instagram_profiles/show.html.erb` (+5 section partials) |
| 06 | `story-people-show` | `/instagram_profiles/:id/people/:person_id` | `instagram_story_people#show` | `app/views/instagram_story_people/show.html.erb` |
| 07 | `posts-index` | `/instagram_posts` | `instagram_posts#index` | `app/views/instagram_posts/index.html.erb` |
| 08 | `post-show` | `/instagram_posts/:id` | `instagram_posts#show` | `app/views/instagram_posts/show.html.erb` |
| 09 | `ai-dashboard` | `/ai_dashboard` | `ai_dashboard#index` | `app/views/ai_dashboard/index.html.erb` |
| 10 | `admin-background-jobs` | `/admin/background_jobs` | `admin/background_jobs#dashboard` | `app/views/admin/background_jobs/dashboard.html.erb` |
| 11 | `admin-failures` | `/admin/background_jobs/failures` (+ `/:id`) | `admin/background_jobs#failures` | `app/views/admin/background_jobs/failures.html.erb` |
| 12 | `admin-issues` | `/admin/issues` | `admin/issues#index` | `app/views/admin/issues/index.html.erb` |
| 13 | `admin-storage` | `/admin/storage_ingestions` | `admin/storage_ingestions#index` | `app/views/admin/storage_ingestions/index.html.erb` |
| 14 | `admin-ai-provider` | `/admin/ai_provider_settings` | `admin/ai_provider_settings#index` | `app/views/admin/ai_provider_settings/index.html.erb` |
| 15 | `admin-mission-control` | `/admin/jobs` | Mission Control engine mount | *(engine)* |
| XX | `overlays` | cross-cutting | sidebar, notifications, modals, queue-health banner | `app/views/layouts/application.html.erb`, `app/views/shared/*` |

## Status matrix

Populated during Phase 6-8. Rows correspond to individual finding IDs
emitted from per-page files. Status moves `open → fixed | follow-up | accepted`.

| Finding ID | Page | Severity | Summary | Status | Commit |
|---|---|---|---|---|---|
| *(empty until Phase 6)* | | | | | |

## Phase log

| Phase | Note file | State |
|---|---|---|
| 1 — UI exploration | `phase-notes/01-exploration.md` | complete (15 pages + overlays) |
| 2 — Interaction coverage | `phase-notes/02-interactions.md` | complete (destructive actions inventoried only) |
| 3 — Background jobs | `phase-notes/03-jobs.md` | complete — purge rake verified, 30 stale payloads dropped |
| 4 — LLM integration | `phase-notes/04-llm.md` | complete — NVIDIA `test_service` round-trip 200 OK in 647 ms |
| 5 — Data / storage | `phase-notes/05-data.md` | complete (Sidekiq retry/dead/scheduled snapshots + `BackgroundJobFailure` counts) |
| 6 — Gap analysis | `FINDINGS.md` | complete |
| 7 — Implementation | commits on `feat/phase13-application-audit` | 5 commits (see below) |
| 8 — Reporting & iteration | this README + `FINDINGS.md` status matrix + `screenshots/after/` | complete |

## Phase 7 commit trail

| Commit | Summary |
|---|---|
| `5eb65c6` | Scaffold audit (README, FINDINGS, pages, phase-notes) |
| `a1876f2` | Fix `F-overlays-I2` — add `public/favicon.ico` to kill dev-log 404 noise |
| `1276601` | Fix `F-story-people-show-C1` + `F-post-show-C1` — `ApplicationController#rescue_from ActiveRecord::RecordNotFound` → styled 404 |
| `98db273` | Fix `F-dashboard-C1` + `F-admin-background-jobs-C1` — `Ops::OrphanedJobClassMiddleware` + `rake jobs:purge_unresolvable` + `excluding_deprovisioned` scope |
| `1eb8e42` | Fix `F-admin-ai-provider-I1` — remove dead "Local provider (legacy)" view block |

Status matrix: 4 of 5 Critical findings fixed in this branch (1 deferred
to Phase 14); 3 Improvement findings fixed; 25+ Improvement/Optional
findings tagged `follow-up` for a Phase 14 UX polish sweep.

## Operator notes

- **Screenshots are local-only.** `docs/audits/*/screenshots/` is
  gitignored to keep the repo lean. Re-run the Phase 1 walk via the
  `@playwright/mcp` server to regenerate them locally:
  `mcp_call_tool browser_navigate` → `browser_take_screenshot` with
  `filename: docs/audits/phase13/screenshots/before/<slug>.png`.
- **Profile isolation:** the MCP sidecar is launched against an ephemeral
  `tmp/audit_profile/` user-data dir, *not* a
  `storage/browser_sessions/<account_id>/` profile. No Instagram login is
  involved; we only audit the Rails UI at `http://localhost:3000`, and
  this prevents colliding with any Sidekiq worker that holds a
  per-account Chromium profile lock
  (cf. `docs/operations/playwright-mcp-sidecar.md`).
- **Destructive admin controls** (Clear all jobs, Retry failure, Import
  cookies, Destroy account) are inventoried in Phase 2 tables but
  **not fired** without explicit per-action confirmation from the
  operator.
- **Empty-state coverage:** the dev DB is sparse (1 account, 1 profile
  per Phase 11's `docs/operations/ui-smoke-findings.md`). Empty-state UX
  is recorded as a finding, not treated as broken behaviour.
- **Finding IDs** are `F-<page-slug>-<severity-letter><n>`, e.g.
  `F-dashboard-C1`, `F-profile-show-I3`.
