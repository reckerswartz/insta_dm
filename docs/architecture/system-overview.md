# System Overview

Last updated: 2026-02-20

## Runtime Components

- Rails app (UI/API/action endpoints)
  - controllers in `app/controllers/`
- Background execution (Active Job + Sidekiq)
  - job classes in `app/jobs/`
  - queue/capsule config in `config/sidekiq.yml` and `config/initializers/sidekiq.rb`
- Data layer (PostgreSQL + Active Storage + pgvector)
  - schema in `db/schema.rb`
- Local AI stack
  - Ruby adapter/client in `app/services/ai/*`
  - Python microservice in `ai_microservice/`
  - Ollama used for text generation (`Ai::OllamaClient`)
- Instagram integration layer
  - main integration service: `app/services/instagram/client.rb`

## Application Entry Surfaces

- Account dashboard / orchestration actions:
  - `InstagramAccountsController` (`app/controllers/instagram_accounts_controller.rb`)
- Profile table + profile detail tabs:
  - `InstagramProfilesController` (`app/controllers/instagram_profiles_controller.rb`)
- Profile action commands (analyze, build history, sync stories, fetch details):
  - `InstagramProfileActionsController` (`app/controllers/instagram_profile_actions_controller.rb`)
- Post-level actions (analyze one post, forward comment):
  - `InstagramProfilePostsController` (`app/controllers/instagram_profile_posts_controller.rb`)
- Workspace queue:
  - `WorkspacesController` (`app/controllers/workspaces_controller.rb`)
- Admin operations dashboard:
  - `Admin::BackgroundJobsController` + service layer in `app/services/admin/background_jobs/`

## Core Data Entities

- `InstagramAccount`
  - auth/session payload, continuous-processing state, cursors, retry/backoff fields
- `InstagramProfile`
  - follow-graph state, DM/story interaction state, profile metadata, tags
- `InstagramProfilePost`
  - captured post row, media attachments, AI status/analysis payload, workspace and pipeline metadata
- `InstagramProfileEvent`
  - immutable-ish event journal for stories/comments/post activity
  - also stores story LLM lifecycle fields (`llm_comment_status`, `llm_generated_comment`)
- `InstagramStory`, `InstagramStoryFace`, `InstagramStoryPerson`
  - persisted story intelligence graph
- `AiAnalysis` + materialized insights tables
  - raw AI run history + query-friendly projection tables
- `BackgroundJobFailure` and `AppIssue`
  - job-failure persistence and deduplicated issue tracking

## Cross-Cutting Metadata Contracts

The app uses JSON metadata fields as state carriers across jobs.

Most important contracts:

- `instagram_profile_posts.metadata["ai_pipeline"]`
  - post-analysis pipeline state machine (`run_id`, `required_steps`, per-step status/result)
- `instagram_profile_posts.metadata["comment_generation_policy"]`
  - why comment generation was blocked/allowed and which missing evidence caused gating
- `instagram_profile_posts.metadata["workspace_actions"]`
  - queue state for workspace cards (`queued`, `running`, `waiting_*`, `ready`, etc.)
- `instagram_profile_posts.metadata["history_build"]`
  - build-history orchestration fields (including face-refresh state)
- `instagram_profile_events.metadata["local_story_intelligence"]`
  - extracted visual/text/story evidence for event-level LLM suggestion generation

## Architectural Pattern Notes

- Controllers are thin and defer to service/query classes for data assembly.
- Admin background-jobs UI follows the same split:
  - query (`FailuresQuery`), snapshot (`DashboardSnapshot`), enrichment (`RecentJobDetailsEnricher`), and payload (`FailurePayloadBuilder`) services.
- High-latency/unstable work (Instagram API/UI calls, AI inference, media processing) is job-driven.
- Resilience patterns are consistent across subsystems:
  - enqueue in batches,
  - persist state transitions in metadata/action logs,
  - emit structured logs + live update broadcasts,
  - degrade gracefully when non-critical operations fail.
