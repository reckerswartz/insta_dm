# Phase 11 UI Smoke Walk Findings

Captured against the live dev instance (`http://localhost:3000`,
account `reckerswartz`, Playwright MCP driver).

## What worked

- **Sidebar nav copy**: `AI Services — NVIDIA Build health` now renders
  correctly (pre-Phase-11 it still said `Local model health`).
- **AI Services page** loads with NVIDIA Build online, 132+ models
  listed, no 500s.
- **Engagement policy pill** on `/instagram_profiles/:id` renders all
  three states end-to-end:
  - neutral profile → `Eligible`
  - `is_business=true, followers=50000` → `Skipped — Profile likely page`
  - `friend` tag applied → `Eligible (friend priority)`
- Account page show (`/instagram_accounts/:id`) renders all panels,
  sync buttons fire jobs that complete, no 500s.

## Gaps / limitations surfaced

1. **Empty follow graph**. The local DB has 1 account + 1 profile
   (`reckerswartz`, which is the account's own mirror). `following=true`
   count = 0, `follows_you=true` count = 0. When the home-story
   carousel sync runs, it visits 10 stories and skips 30 of them with
   `profile_not_in_network` — so no rows enter the archive.
   **Action required**: operator must click
   `Sync Followers/Following (Background)` at least once before any
   story auto-reply can fire. Recommend adding a first-run hint to the
   account page when the follower count is 0.
2. **Dashboard `24h failures = 139` / `24h auth failures = 35` are
   stale**. They're dominated by the deleted `CheckLocalAiHealthJob`
   probes against the Ollama stack. The rolling window expires them
   over time but the top-level counters look alarming on first load.
   Candidate follow-up: filter out `provider=local_ai_stack` from the
   24h aggregator, or reset the counters at Phase 5/10 migration time.
3. **End-to-end story-reply → send** couldn't complete during the
   smoke walk because of gap #1 (no profiles with stories). The code
   path is unit-covered via
   `spec/jobs/sync_instagram_profile_stories_job_spec.rb` Phase 11
   describe block and `spec/models/instagram_profile_spec.rb`.
4. **Profile show — tag management** works via the existing
   `#profile_tags_section` card, but the new `engagement_excluded`
   tag is only available as a checkbox after Phase 11's addition to
   `InstagramProfiles::ShowSnapshotService::AVAILABLE_TAGS`. Operators
   who had a Turbo Frame cached before the deploy need a hard refresh.

## Not observed broken

- `/workspace/actions`, `/instagram_profiles`, `/instagram_posts`
  all load with no JS errors on this run.
- The NVIDIA `Run test` and `Run all tests` buttons on the AI Services
  page were not exercised during this walk but the supporting
  `AiDashboard::ServiceTester` is covered by existing specs via
  `Ai::NvidiaClient#list_models!`.
