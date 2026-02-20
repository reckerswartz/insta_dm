# Documentation Index

Last updated: 2026-02-20

This documentation set is organized by how the system is built and operated. Use this file as the primary navigation entrypoint.

## Read First (Onboarding Order)

1. Project setup and local run:
   - `README.md`
2. High-level runtime architecture:
   - `docs/architecture/system-overview.md`
3. Data model and table ownership:
   - `docs/architecture/data-model-reference.md`
4. AI orchestration and provider layer:
   - `docs/architecture/ai-services-architecture.md`
5. Day-2 troubleshooting baseline:
   - `docs/operations/debugging-playbook.md`

## Architecture Notes

- Runtime boundaries and entry surfaces:
  - `docs/architecture/system-overview.md`
- Instagram client facade decomposition and extension rules:
  - `docs/architecture/instagram-client-facade-guidelines.md`
- AI service orchestration and state contracts:
  - `docs/architecture/ai-services-architecture.md`
- Face identity resolution and video/media processing:
  - `docs/architecture/face-identity-and-video-pipeline.md`
- Table-level reference and metadata contract index:
  - `docs/architecture/data-model-reference.md`

## Technical Workflows

- Account sync, refresh, continuous processing, and DM delivery:
  - `docs/workflows/account-sync-and-processing.md`
- Post ingestion and multi-step AI pipeline:
  - `docs/workflows/post-analysis-pipeline.md`
- Story ingestion, intelligence extraction, and reply gating:
  - `docs/workflows/story-intelligence-pipeline.md`
- Workspace action queue lifecycle:
  - `docs/workflows/workspace-actions-queue.md`

## Operational Guidance

- Queue topology, recurring jobs, and retry semantics:
  - `docs/operations/background-jobs-and-schedules.md`
- Scenario-based debugging procedures:
  - `docs/operations/debugging-playbook.md`

## Query and UI Retrieval Surfaces

- Query services and metadata fields used by tables/dashboards:
  - `docs/components/lookups-and-query-surfaces.md`

## Changelog

- Policy:
  - `docs/changelog/README.md`
- Entries:
  - `docs/changelog/2026-02-20.md`

## Folder Layout

```text
docs/
  architecture/   # runtime architecture, AI services, data model, media/face pipeline
  workflows/      # end-to-end processing paths
  operations/     # runbooks, scheduling, debugging
  components/     # query surfaces and shared lookup contracts
  changelog/      # documentation change history
```

## Maintenance Rules

When behavior changes, update the owning doc in the same PR.

Use this mapping:

- Changes under `app/services/instagram/client.rb` or client support modules:
  - update `docs/architecture/instagram-client-facade-guidelines.md`
- Changes under `app/jobs/*sync*`, `app/services/pipeline/*`:
  - update `docs/workflows/account-sync-and-processing.md`
- Changes under `app/jobs/process_post_*`, `app/jobs/finalize_post_analysis_pipeline_job.rb`, `app/services/ai/post_analysis_pipeline_state.rb`:
  - update `docs/workflows/post-analysis-pipeline.md`
- Changes under `app/jobs/sync_instagram_profile_stories_job.rb`, `app/services/story_ingestion_service.rb`, `app/services/story_processing_service.rb`:
  - update `docs/workflows/story-intelligence-pipeline.md`
- Changes under `app/services/workspace/actions_todo_queue_service.rb`, `app/jobs/workspace_process_actions_todo_post_job.rb`:
  - update `docs/workflows/workspace-actions-queue.md`
- Changes to recurring schedules, queue routing, or retry policy:
  - update `docs/operations/background-jobs-and-schedules.md`
- Changes to lookup/query behavior for profile/event/dashboard/story archive surfaces:
  - update `docs/components/lookups-and-query-surfaces.md`
