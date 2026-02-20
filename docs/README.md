# Documentation Index

Last updated: 2026-02-20

This documentation set is organized around how the application actually runs in production-like environments: controller entry points, background-job orchestration, pipeline state, and debugging surfaces.

## Start Here

- System architecture and component boundaries:
  - `docs/architecture/system-overview.md`

## Core Workflows

- Account sync, profile refresh, continuous processing, and DM delivery:
  - `docs/workflows/account-sync-and-processing.md`
- Profile post media + AI analysis pipeline:
  - `docs/workflows/post-analysis-pipeline.md`
- Story ingestion, story intelligence processing, and reply gating:
  - `docs/workflows/story-intelligence-pipeline.md`
- Workspace action queue (operator-facing action backlog):
  - `docs/workflows/workspace-actions-queue.md`

## Data Retrieval and Lookups

- Query services and metadata contracts used by UI/API lookups:
  - `docs/components/lookups-and-query-surfaces.md`

## Operations and Debugging

- Queue topology, recurring schedules, and retry semantics:
  - `docs/operations/background-jobs-and-schedules.md`
- Scenario-based debugging playbook:
  - `docs/operations/debugging-playbook.md`

## Changelog

- Changelog policy:
  - `docs/changelog/README.md`
- Chronological updates:
  - `docs/changelog/2026-02-20.md`

## Maintenance Rules

When behavior changes, update the workflow file that owns that path in the same PR.

Use this mapping:

- Changes under `app/jobs/*sync*`, `app/services/pipeline/*`, `app/services/instagram/client.rb`:
  - update `docs/workflows/account-sync-and-processing.md`
- Changes under `app/jobs/process_post_*`, `app/jobs/finalize_post_analysis_pipeline_job.rb`, `app/services/ai/post_analysis_pipeline_state.rb`:
  - update `docs/workflows/post-analysis-pipeline.md`
- Changes under `app/jobs/sync_instagram_profile_stories_job.rb`, `app/services/story_ingestion_service.rb`, `app/services/story_processing_service.rb`:
  - update `docs/workflows/story-intelligence-pipeline.md`
- Changes under `app/services/workspace/actions_todo_queue_service.rb`, `app/jobs/workspace_process_actions_todo_post_job.rb`:
  - update `docs/workflows/workspace-actions-queue.md`
- Changes to recurring schedules, queue routing, or retry policy:
  - update `docs/operations/background-jobs-and-schedules.md`
