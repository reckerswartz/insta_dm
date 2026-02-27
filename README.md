# Unofficial Instagram Messaging App (Rails + Selenium)

This application manages Instagram outreach workflows in one Rails app:
- authenticate and maintain account sessions,
- sync followers/following and profile metadata,
- run post/story intelligence pipelines,
- generate AI-assisted comments,
- manage DM delivery and retry state.

## Important Note
Use this only for accounts and activity you are authorized to automate. Instagram behavior and restrictions can change without notice.

## Stack
- Ruby on Rails 8
- PostgreSQL + pgvector
- Sidekiq + Redis
- Selenium WebDriver + Chrome/ChromeDriver
- Local AI microservice + Ollama

## Quick Start

Prerequisites:
- Docker (for local Postgres/Redis)
- Ruby 3.4.1
- Node + Yarn
- Google Chrome + ChromeDriver

Run locally:

```bash
docker compose up -d postgres redis
bundle install
yarn install
bin/rails db:prepare
bin/dev
```

App URL: `http://localhost:3000`

## Core Commands

```bash
# Web + jobs (development)
bin/dev

# Jobs only
bin/jobs

# Test suite
bundle exec rspec

# Parallel specs
bin/parallel_rspec

# Optional AI feature usage/failure evidence report (for prune decisions)
bin/ai_feature_evidence_report
```

Evidence automation:
- `AnalyzeAiFeatureEvidenceJob` runs on cron (see `config/sidekiq_schedule.yml`) and logs usage/failure recommendations for candidate legacy AI features.

Diagnostics specs:

```bash
# Full diagnostics suite
bundle exec rspec spec/diagnostics

# UI diagnostics only (requires running app server)
bundle exec rspec spec/diagnostics --tag diagnostic_ui
```

## Configuration

### Rails Credentials
Manage app credentials with:

```bash
bin/rails credentials:edit
```

Common keys:
- `instagram.username`
- `instagram.headless`
- `admin.user`
- `admin.password`

### Local AI Microservice
`bin/dev` now verifies local AI readiness before workers start when local AI is required.

Default behavior:
- `START_LOCAL_AI=auto` (default): if `USE_LOCAL_AI_MICROSERVICE=true` (default), `bin/dev` will attempt to start local AI services and fail fast if they are not healthy.
- `START_LOCAL_AI=true`: always require and auto-start local AI services.
- `START_LOCAL_AI=false`: skip auto-start and continue without local AI readiness gating.

Health and lifecycle commands:

```bash
# Combined dev health (web + local AI)
bin/dev health

# Local AI stack only
bin/local_ai_services status
bin/local_ai_services restart
bin/local_ai_services logs
bin/local_ai_services cleanup-models
```

Manual local AI setup:

```bash
cd ai_microservice
./setup.sh
./start_microservice.sh
```

Useful env vars:
- `LOCAL_AI_SERVICE_URL` (default `http://localhost:8000`)
- `OLLAMA_URL` (default `http://localhost:11434`)
- `OLLAMA_MODEL` (default `llama3.2:3b`)
- `OLLAMA_VISION_MODEL` (default `llama3.2-vision:11b`)

### Active Record Encryption Bootstrap

```bash
bin/rails app:security:bootstrap_encryption
```

This initializes encryption keys in credentials. `bin/setup` runs it automatically.

## Documentation

Use `docs/README.md` as the canonical entrypoint.

- System and component architecture:
  - `docs/architecture/system-overview.md`
  - `docs/architecture/instagram-client-facade-guidelines.md`
  - `docs/architecture/ai-services-architecture.md`
  - `docs/architecture/face-identity-and-video-pipeline.md`
  - `docs/architecture/data-model-reference.md`
- Technical workflows:
  - `docs/workflows/account-sync-and-processing.md`
  - `docs/workflows/post-analysis-pipeline.md`
  - `docs/workflows/story-intelligence-pipeline.md`
  - `docs/workflows/workspace-actions-queue.md`
- Operations and debugging:
  - `docs/operations/background-jobs-and-schedules.md`
  - `docs/operations/debugging-playbook.md`
- Query/lookups reference:
  - `docs/components/lookups-and-query-surfaces.md`
- Documentation changelog:
  - `docs/changelog/`

## Maintenance Rule
When behavior changes, update the matching workflow/operations/architecture document in the same PR.
