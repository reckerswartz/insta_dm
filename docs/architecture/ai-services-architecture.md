# AI Services Architecture

Last updated: 2026-02-20

This document covers the AI service layer: how analysis runs are orchestrated, which providers are called, how results are cached and materialized, and how comment generation is gated.

## Service Map

```
Ai::Runner                         ← orchestrator: provider selection, cache, quality metrics
├── Ai::ProviderRegistry           ← resolves provider class from setting key
├── Ai::LocalMicroserviceClient    ← HTTP client for Python microservice
├── Ai::OllamaClient               ← Ollama text generation
├── Ai::InsightSync                ← materializes AI output into insight tables
└── Ai::ApiUsageTracker            ← per-call usage tracking → AiApiCall table

Ai::PostAnalysisPipelineState      ← step state machine for post analysis
Ai::PostCommentGenerationService   ← evidence-gated comment generation
├── Ai::PostCommentGeneration::SignalContext    ← evidence extraction/normalization
└── Ai::PostCommentGeneration::PolicyPersistence← policy + metadata persistence
Ai::PostAnalysisContextBuilder     ← assembles analysis payloads
Ai::ProfileAnalyzer                ← profile-level analysis orchestration
Ai::PostAnalyzer                   ← post-level analysis orchestration
Ai::ProfileDemographicsAggregator  ← multi-pass demographics inference
Ai::ProfileHistoryBuildService     ← narrative history assembly for LLM context
Ai::ProfileHistoryNarrativeBuilder ← text builder for history chunks
Ai::LocalEngagementCommentGenerator← story/event comment generation
Ai::CommentRelevanceScorer         ← ranks generated comment candidates
Ai::ProfileCommentPreparationService ← builds profile context for comment gen
Ai::ProfileAutoTagger              ← automatic tag application from AI results
Ai::VerifiedStoryInsightBuilder    ← builds verified story intelligence for LLM prompts
Ai::PostOcrService                 ← OCR extraction from post media

LlmComment::GenerationService      ← job-level workflow, locking, retries/skips
└── LlmComment::EventGenerationPipeline ← event-level context/policy/model/ranking orchestration
```

## Ai::Runner — Analysis Orchestrator

File: `app/services/ai/runner.rb`

Central entry point for all AI analysis. Every analysis call goes through `Runner#analyze!`.

### Execution Flow

1. **Fingerprint check**: compute `media_fingerprint` from media bytes/URL for dedup.
2. **Cache lookup**: if `allow_cached`, find `AiAnalysis` with same `(purpose, media_fingerprint, status=completed)`. Reuse if found.
3. **Provider selection**: load enabled `AiProviderSetting` rows, filter by `supports_purpose?`, filter by daily usage limit (`Ai::ApiUsageTracker`), order by priority.
4. **Inference**: call selected provider's `analyze!` method with payload + media.
5. **Record creation**: persist `AiAnalysis` row with prompt, response, parsed JSON, quality metrics.
6. **Materialized sync**: call `Ai::InsightSync` to project results into query-friendly tables.
7. **Quality metrics**: compute `input_completeness_score`, `confidence_score`, `evidence_count`, `signals_detected_count`, `prompt_version`, `schema_version`.

### Cache Reuse

When a cached analysis is reused:
- A new `AiAnalysis` row is created with `cache_hit=true` and `cached_from_ai_analysis_id` pointing to the source.
- The analysis JSON is deep-copied, not shared by reference.
- Materialized insights are re-synced to ensure the new analyzable has current projection rows.

### Provider Options

`provider_options` hash controls provider behavior:
- `force_provider`: override provider selection
- `visual_only`: restrict to vision-capable providers
- Queue/capsule routing is handled by the calling job, not the runner

## Ai::LocalMicroserviceClient — Python Microservice Client

File: `app/services/ai/local_microservice_client.rb`

HTTP client wrapping the local Python AI microservice (`ai_microservice/`).

### Base URL

Configured via `LOCAL_AI_MICROSERVICE_URL` env var, defaults to `http://127.0.0.1:5001`.

### Supported Operations

| Method | Endpoint | Purpose |
|---|---|---|
| `test_connection!` | `GET /health` | Health check |
| `analyze_image_bytes!` | `POST /analyze/image` | Image analysis (multipart upload) |
| `analyze_image_uri!` | `POST /analyze/image` | Image analysis from URL |
| `analyze_video_bytes!` | `POST /analyze/video` | Video analysis (multipart upload) |
| `fetch_video_operation!` | `GET /operations/:name` | Poll async video operation |
| `generate_text_json!` | `POST /generate` | Text generation via Ollama |
| `detect_faces_and_ocr!` | `POST /analyze/image` | Face detection + OCR + object detection |
| `analyze_video_story_intelligence!` | `POST /analyze/video` | Video story intelligence extraction |

### Response Normalization

The client normalizes microservice responses into a Google Vision API-compatible format internally:
- `convert_vision_response`: maps local detection output to `faceAnnotations`, `textAnnotations`, `labelAnnotations`
- `convert_video_response`: maps video analysis to `annotationResults` format
- All bounding boxes are normalized to `{x, y, width, height}` format

### Error Handling

- Validates input bytes before upload (`validate_image_bytes!`, `validate_video_bytes!`)
- Unpacks response with `unpack_response_payload!` — raises on missing expected keys or error payloads
- Extracts HTTP error messages from JSON or raw response bodies

## Ai::OllamaClient — Text Generation

File: `app/services/ai/ollama_client.rb`

Direct HTTP client for Ollama API (`/api/generate` endpoint). Used by `Ai::LocalEngagementCommentGenerator` and other text-generation paths.

- Base URL: `OLLAMA_URL` env var, defaults to `http://127.0.0.1:11434`
- Supports `model`, `prompt`, `temperature`, `max_output_tokens` parameters
- Returns parsed JSON with structured response

## Ai::PostAnalysisPipelineState — Step State Machine

File: `app/services/ai/post_analysis_pipeline_state.rb`

Manages the multi-step post analysis pipeline stored in `post.metadata["ai_pipeline"]`.

### Pipeline Lifecycle

```
start! → queued steps → running → succeeded/failed/skipped → pipeline completed/failed
```

### Steps

| Step | Queue | Purpose |
|---|---|---|
| `visual` | `ai_visual_queue` | Baseline image/video analysis |
| `face` | `ai_face_queue` | Face detection and recognition |
| `ocr` | `ai_ocr_queue` | Text extraction |
| `video` | `video_processing_queue` | Video context extraction |
| `metadata` | `ai_metadata_queue` | Metadata tagging (runs after core steps) |

### State Contract

```json
{
  "run_id": "uuid",
  "status": "running|completed|failed",
  "required_steps": ["visual", "face", "ocr"],
  "task_flags": {},
  "steps": {
    "visual": {
      "status": "queued|running|succeeded|failed|skipped",
      "attempts": 1,
      "job_id": "...",
      "result": {},
      "error": null
    }
  }
}
```

## Ai::PostCommentGenerationService — Comment Generation

File: `app/services/ai/post_comment_generation_service.rb`

Generates contextual comments for profile posts. This is the final step before a post becomes "ready" in the workspace queue.

### Evidence Gating

Comment generation requires:
1. **Post analysis** — `ai_status=analyzed` with valid `analysis` JSON
2. **Profile history** — narrative history chunks built by `ProfileHistoryBuildService`
3. **Image description** — generated from visual analysis output

When `enforce_required_evidence` is true (default), missing evidence blocks generation and writes the reason to `post.metadata["comment_generation_policy"]`.

### Generation Flow

1. Build preparation summary via `Ai::ProfileCommentPreparationService`
2. Build normalized evidence context via `Ai::PostCommentGeneration::SignalContext`
3. Build conversational voice from profile history and insights
4. Call `Ai::LocalEngagementCommentGenerator` to generate candidates
5. Persist policy + output through `Ai::PostCommentGeneration::PolicyPersistence`
6. Update post analysis/metadata in one write path

### Blocked Policy Metadata

When blocked, `post.metadata["comment_generation_policy"]` stores:

```json
{
  "status": "blocked",
  "reason_code": "missing_required_evidence",
  "missing_signals": ["profile_history", "image_description"],
  "checked_at": "2026-02-20T..."
}
```

## LlmComment::EventGenerationPipeline — Event LLM Pipeline

File: `app/services/llm_comment/event_generation_pipeline.rb`

Moves story-event comment generation orchestration out of model concern methods.

### Responsibilities

1. Build event comment context (`build_comment_context` on event model).
2. Persist validated/local story intelligence snapshots.
3. Enforce intelligence availability and verified policy gates.
4. Run local generator + relevance ranking.
5. Persist selected comment and ranked metadata payload.
6. Emit progress/completion broadcasts.

See also: `docs/architecture/comment-generation-refactor-guidelines.md`.

## Ai::InsightSync — Materialized Table Projection

File: `app/services/ai/insight_sync.rb`

Syncs raw `AiAnalysis` JSON into query-friendly tables:
- `instagram_profile_insights` + `instagram_profile_message_strategies` + `instagram_profile_signal_evidences` (for profile analysis)
- `instagram_post_insights` + `instagram_post_entities` (for post analysis)

Called automatically by `Ai::Runner` after every successful analysis run.

## Ai::ApiUsageTracker — Usage Tracking

File: `app/services/ai/api_usage_tracker.rb`

Tracks per-call AI usage into `ai_api_calls` table. Provides:
- Thread-local context injection via `with_context` block
- Daily usage counting for rate-limit enforcement in `Runner#filter_settings_by_daily_limit`
- Category and operation classification for reporting

## Provider Architecture

### Ai::ProviderRegistry

Maps provider keys (e.g. `"local"`) to provider classes.

### Provider Interface

Each provider must implement:
- `analyze!(payload:, media:, purpose:)` → returns `{ response_text:, analysis: }`
- Providers live in `app/services/ai/providers/`

### Current Providers

- `local` — routes through `Ai::LocalMicroserviceClient` for vision + `Ai::OllamaClient` for text
