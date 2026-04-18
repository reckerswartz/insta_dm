# Unofficial Instagram Messaging App (Rails + Playwright + NVIDIA Build)

This application manages Instagram outreach workflows in one Rails app:
- authenticate and maintain account sessions via a per-account persistent Chromium profile,
- sync followers/following and profile metadata,
- run post/story intelligence pipelines on NVIDIA Build (text + vision),
- generate AI-assisted comments and replies,
- manage DM delivery and retry state.

## Important Note
Use this only for accounts and activity you are authorized to automate. Instagram behavior and restrictions can change without notice.

## Stack
- Ruby on Rails 8
- PostgreSQL (pgvector optional; the runtime does not require it)
- Sidekiq + Redis
- **Playwright** driving Chromium via `playwright-ruby-client` (with an `Instagram::Browser::SeleniumApiShim` translation layer so the legacy facade keeps working)
- **NVIDIA Build** for all text, vision, and embedding inference (one API key, five role rows in `ai_provider_settings`)
- FFmpeg for optional video keyframe extraction

Selenium and the legacy Python AI microservice + Ollama stack have been migrated off; see the `Migration` section below.

## Quick Start

Prerequisites:
- Ruby 3.4.1+
- Node 20+ and Yarn 1.x (the repo uses Yarn Classic)
- PostgreSQL 15+ available on `localhost:5432`
- Redis 7+ available on `localhost:6379`
- FFmpeg on `$PATH` (used for video keyframe extraction)

Run locally:

```bash
bundle install
yarn install
# Install the Playwright-managed Chromium (first run only; ~112 MB download).
# NODE_OPTIONS is needed on hosts that rely on the system CA bundle.
NODE_OPTIONS="--use-system-ca" npx playwright install chromium
bin/rails db:prepare
bin/dev
```

App URL: `http://localhost:3000`

### NVIDIA API key

The app reads the shared NVIDIA Build key from Rails credentials:

```bash
bin/rails credentials:edit
# add:
# nvidia:
#   api_key: nvapi-...
#   base_url: https://integrate.api.nvidia.com/v1   # optional override
```

Five role rows (`text_fast`, `text_quality`, `vision_primary`, `vision_fallback`, `embedding`) auto-seed in `ai_provider_settings` the first time `Ai::ProviderRegistry.ensure_settings!` runs. With the credential key present they default to `enabled=true`. Enable / disable without a deploy:

```bash
bin/rails ai:nvidia:enable       # flip every nvidia row enabled
bin/rails ai:nvidia:disable      # fall back to the legacy local provider
bin/rails ai:nvidia:test_key     # GET /v1/models for every enabled role
bin/rails ai:nvidia:smoke        # tiny chat + embedding round-trip
```

Per-row model and concurrency tuning lives in **Admin → AI Provider Settings** (`/admin/ai_provider_settings`). Paste or rotate keys from that page; blank fields do not clobber saved keys.

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

## Configuration

### Browser driver (Selenium | Playwright)

Post-migration, Playwright is the production driver. The legacy Selenium path is kept behind a feature flag for rollback:

```bash
export INSTAGRAM_BROWSER_DRIVER=playwright   # default post-Phase-3
export INSTAGRAM_BROWSER_DRIVER=selenium     # emergency rollback
```

Per-account persistent Chromium profiles live under `storage/browser_sessions/<account_id>/`. See `docs/operations/browser-sessions.md` for login, backup/restore, and troubleshooting.

### Legacy AI pipeline

Face detection, Whisper transcription, and PaddleOCR are soft-deprecated. The pipeline step jobs still run but short-circuit to a "skipped" payload. Re-enable the legacy path per-shell with:

```bash
LEGACY_AI_PIPELINE_ENABLED=true bin/dev
```

The `ai_microservice/` Python stack and YOLOv8 weights have been removed from the repo; turn the flag back on only after standing up those services externally.

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
  - `docs/architecture/nvidia-provider.md` (Phase 4 provider + router + role model)
  - `docs/architecture/face-identity-and-video-pipeline.md` (deprecated, retained for rollback)
  - `docs/architecture/data-model-reference.md`
- Technical workflows:
  - `docs/workflows/account-sync-and-processing.md`
  - `docs/workflows/post-analysis-pipeline.md`
  - `docs/workflows/story-intelligence-pipeline.md`
  - `docs/workflows/workspace-actions-queue.md`
- Operations and debugging:
  - `docs/operations/background-jobs-and-schedules.md`
  - `docs/operations/browser-sessions.md` (Phase 2 persistent profile layout)
  - `docs/operations/debugging-playbook.md`
- Query/lookups reference:
  - `docs/components/lookups-and-query-surfaces.md`
- Documentation changelog:
  - `docs/changelog/`

## Migration

The repo went through a multi-phase migration in 2026-04:

- **Phase 1:** NVIDIA Build provider scaffolded alongside LocalProvider.
- **Phase 2:** Playwright runtime + per-account persistent contexts introduced (additive).
- **Phase 3:** Instagram::Client facade ported to Playwright (12 sub-steps) with a Selenium-API shim so the DOM-heavy modules kept working.
- **Phase 4:** AI callers repointed to NVIDIA via the existing `Ai::Runner` + a new `Ai::ChatClientFactory`. Face/OCR/Whisper pipelines soft-deprecated behind `LEGACY_AI_PIPELINE_ENABLED`. Added `Ai::VlmPeopleSummaryService` as a VLM substitute for the face-identity stack.
- **Phase 5:** Deleted `ai_microservice/`, `yolov8n.pt`, `bin/local_ai_services` + friends, `aws-sdk-rekognition`. `bin/dev` stopped preflighting the Python microservice by default.

See commit messages on `feat/playwright-nvidia-migration` for per-phase detail.

## Maintenance Rule
When behavior changes, update the matching workflow/operations/architecture document in the same PR.
