# NVIDIA Provider

Phase 4 of the 2026-04 migration repointed all AI inference from the legacy
Python microservice + Ollama stack to **NVIDIA Build**
(`https://integrate.api.nvidia.com/v1`). This document covers the provider
layout, role model, credentials, runtime routing, and operational
tuneables.

## Layout

```
app/services/ai/
├── nvidia_client.rb                 # OpenAI-compatible HTTP client
├── nvidia_model_router.rb           # role -> AiProviderSetting row resolver
├── nvidia_rate_limiter.rb           # Redis-backed per-setting RPM bucket
├── nvidia_ollama_compat_client.rb   # Ollama-shaped shim for generators
├── chat_client_factory.rb           # picks Ollama vs NVIDIA at runtime
├── providers/
│   ├── base_provider.rb             # shared interface (analyze_profile!, analyze_post!, test_key!)
│   ├── local_provider.rb            # legacy Ollama-backed provider (fallback)
│   └── nvidia_provider.rb           # NVIDIA Build provider
├── vlm_people_summary_service.rb    # VLM substitute for face-identity
└── legacy_pipeline_config.rb        # LEGACY_AI_PIPELINE_ENABLED flag
```

## Role model

`AiProviderSetting` rows are indexed by `(provider, role)`. The NVIDIA
provider uses five role rows; operators pick a model per role in
**Admin → AI Provider Settings**.

| role              | default model                                  | used by                                    |
|-------------------|------------------------------------------------|--------------------------------------------|
| `text_fast`       | `meta/llama-3.1-8b-instruct`                   | Ollama-shim `generate()` without quality hint, comment generator fast tier |
| `text_quality`    | `meta/llama-3.3-70b-instruct`                  | `analyze_profile!`, text-only `analyze_post!`, quality-tier comment generation |
| `vision_primary`  | `meta/llama-3.2-90b-vision-instruct`           | `analyze_post!` with image media, `VlmPeopleSummaryService` |
| `vision_fallback` | `microsoft/phi-3-vision-128k-instruct`         | `VlmPeopleSummaryService` fallback         |
| `embedding`       | `nvidia/nv-embedqa-e5-v5`                      | `provider.embed!(input:)`                  |

Fallback chains are defined in `Ai::NvidiaModelRouter::DEFAULT_FALLBACKS`;
if a primary role row is disabled or has no key, the router walks the
fallback list before raising `UnconfiguredRoleError`.

## Credentials

One shared key in `config/credentials.yml.enc`:

```yaml
nvidia:
  api_key: nvapi-...
  base_url: https://integrate.api.nvidia.com/v1    # optional
```

`AiProviderSetting#effective_api_key` prefers a row-level key (e.g. to
rotate a single role) and falls back to the shared credential key. A
blank form field on the admin page does **not** clobber a saved key.

## Provider contract

`Ai::Providers::NvidiaProvider` implements the same interface the Runner
already drives:

- `#analyze_profile!(profile_payload:, media: nil)` → uses `text_quality`.
  System prompt pins the exact JSON schema `Ai::InsightSync.sync_profile!`
  consumes; `response_format: { type: json_object }` forces strict JSON;
  a defensive parser strips ```json``` fences and extracts the first
  `{...}` if `JSON.parse` fails. Every required key is coerced with
  safe defaults.
- `#analyze_post!(post_payload:, media: nil, provider_options: {})` →
  uses `vision_primary` when `media` has image bytes, else `text_quality`.
  Videos are sampled via `VideoFrameExtractionService` and the first
  `NVIDIA_VISION_MAX_IMAGES` (default 2) keyframes are sent as
  `image_url` content parts.
- `#chat!(role:, messages:, **opts)` / `#embed!(input:, role:, **opts)`
  are the low-level helpers other services use.
- `#test_key!` → `GET /v1/models` via the resolved text role.

## Runtime routing

`Ai::Runner` already iterates `AiProviderSetting.enabled_settings`
ordered by priority ascending. Phase 4.2 set `nvidia` priority = 2 and
`local` priority = 20, so NVIDIA is tried first. If the first provider
raises, the runner records a failed `AiAnalysis` row and falls through
to the next provider (typically `local`, which still sits idle unless
operators keep it enabled).

Comment generators (`Ai::LocalEngagementCommentGenerator` and friends)
consume the factory:

```ruby
Ai::ChatClientFactory.build
# => Ai::NvidiaOllamaCompatClient when any nvidia text role is enabled + keyed
# => Ai::OllamaClient               otherwise
```

The compat client presents the Ollama signature (`generate(model:,
prompt:, ...)` / `chat(model:, messages:, ...)`), so the generators'
existing prompt-engineering surface is unchanged. Model-name heuristics
translate Ollama identifiers to NVIDIA roles:

- strings containing `vision` → `vision_primary`
- strings containing `quality` → `text_quality`
- exact matches of `OLLAMA_QUALITY_MODEL` (when distinct from the base)
  → `text_quality`
- explicit override: `model: "role:text_quality"` etc.
- everything else → `text_fast`

## Concurrency tier

`Ops::AiServiceQueueRegistry.concurrency_for(service:)` picks between
the legacy and NVIDIA tiers based on
`AiProviderSetting.any? { |s| s.provider == "nvidia" && s.enabled && s.api_key_present? }`.
Values are cached for the life of the Sidekiq process and reset with
`Ops::AiServiceQueueRegistry.reset_nvidia_tier_cache!`.

| service                        | legacy default | nvidia default | nvidia max |
|--------------------------------|----------------|----------------|------------|
| `llm_comment_generation`       | 1              | 8              | 16         |
| `post_comment_generation`      | 1              | 8              | 16         |
| `visual_analysis`              | 1              | 8              | 16         |
| `profile_post_image_description` | 1            | 6              | 12         |
| `profile_analysis_runner`      | 1              | 4              | 12         |
| `post_analysis_runner`         | 1              | 4              | 12         |
| `pipeline_orchestration`       | 1              | 4              | 10         |
| `metadata_tagging`             | 1              | 4              | 10         |
| `story_analysis`               | 1              | 4              | 10         |
| `profile_history_build`        | 1              | 2              | 6          |
| `face_analysis`, `ocr_analysis`, `video_analysis`, `face_refresh` | 1 | 1 | unchanged |

Env overrides (`SIDEKIQ_AI_<ROLE>_CONCURRENCY`) clamp against the
active tier's min/max. Soft-deprecated lanes stay at 1 to avoid
burning NVIDIA quota on short-circuited jobs.

## Rate limiting

`Ai::NvidiaRateLimiter` is a Redis-backed sliding-window counter. Each
`AiProviderSetting` row carries an optional `rate_limit_rpm`; the client
consults the limiter before every call and blocks up to 30 s waiting
for a slot, then raises `Rejected`. The limiter fails open if Redis is
unavailable, preferring a single request through to blocking the
whole worker.

## Ops tasks

```bash
bin/rails ai:nvidia:test_key   # GET /v1/models for every enabled role
bin/rails ai:nvidia:smoke      # chat + embedding round-trip
bin/rails ai:nvidia:enable     # enabled=true on every nvidia row
bin/rails ai:nvidia:disable    # enabled=false; Ai::Runner falls back to local
```

## Soft-deprecated legacy pipeline

`LEGACY_AI_PIPELINE_ENABLED=true` reactivates the face / OCR / whisper /
local-video pipeline steps. They default to no-oping with a "skipped"
payload so the pipeline state machine still completes. The Ruby service
classes and tables remain on disk (see
`docs/architecture/face-identity-and-video-pipeline.md`) for audit and
rollback; Phase 5 only deleted the Python microservice + CLI tooling.
