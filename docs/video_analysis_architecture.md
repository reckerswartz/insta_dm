# Video Analysis Architecture

## Purpose
Define a deterministic media-analysis architecture for captured profile posts so that:

1. true images are processed as images,
2. image-like videos (single photo + music) are processed as images,
3. only true dynamic videos go through full video analysis.

This document reviews the current implementation and defines the target architecture.

## Scope
- Capture and persistence of profile post media
- Media-type detection and routing
- Visual/video/face/OCR extraction
- Comment-generation inputs and gating

Primary components in the current codebase:
- `AnalyzeInstagramProfilePostJob`
- `Ai::PostAnalysisContextBuilder`
- `ProcessPostVisualAnalysisJob`
- `ProcessPostVideoAnalysisJob`
- `VideoFrameChangeDetectorService`
- `Ai::Providers::LocalProvider`
- `Ai::PostCommentGenerationService`

## Current-System Review

### What works today
- Source media is ingested from Instagram with `media_type`, `image_url`, and `video_url` hints.
- Final attached media type is determined from Active Storage blob content type.
- Video frame-change classification already exists via `VideoFrameChangeDetectorService`:
  - `processing_mode = static_image` when sampled frames are near-identical.
  - `processing_mode = dynamic_video` when frames differ significantly.
- `Ai::Providers::LocalProvider` already routes static videos to image analysis using a representative frame.

### Gaps to close
1. Route decision is not a first-class pipeline contract.
- Media is treated as "video" at pipeline entry when blob MIME is video; static/dynamic is resolved later.
2. Video classification is duplicated.
- Frame-change logic runs in both provider-side flow and `ProcessPostVideoAnalysisJob`.
3. "Image with music" is not explicitly represented as canonical media class.
- It is inferred indirectly as `video_processing_mode=static_image`.

These gaps can cause inconsistent behavior and make it harder to guarantee image-like videos always follow the image path.

## Target Architecture

### 1) Canonical Media Classification (first step)
Introduce a single decision step before downstream analysis jobs:

- Input signals:
  - source hints: Instagram `media_type`, `video_url`, `image_url`
  - stored blob MIME/content type
  - frame-change classifier output (when blob is video)
- Output contract:
  - `container_type`: `image` or `video`
  - `semantic_type`: `image`, `static_video_image`, or `dynamic_video`
  - `analysis_route`: `image_pipeline` or `video_pipeline`
  - `confidence`, `reason_codes`, `detector_metadata`

Recommended persisted metadata shape:

```json
{
  "media_classification": {
    "container_type": "video",
    "semantic_type": "static_video_image",
    "analysis_route": "image_pipeline",
    "confidence": 0.93,
    "reason_codes": ["frame_change_static", "video_has_representative_frame"],
    "detector_metadata": {
      "max_mean_diff": 0.8,
      "diff_threshold": 2.5,
      "sampled_frames": 3
    },
    "classified_at": "2026-02-19T00:00:00.000Z"
  }
}
```

### 2) Routing Rule

Decision tree:

1. If blob MIME is image -> `semantic_type=image`, `analysis_route=image_pipeline`.
2. If blob MIME is video:
   - run frame-change detector once,
   - if `processing_mode=static_image` -> `semantic_type=static_video_image`, `analysis_route=image_pipeline`,
   - else -> `semantic_type=dynamic_video`, `analysis_route=video_pipeline`.
3. If classifier fails:
   - conservative fallback: `analysis_route=video_pipeline`,
   - store failure reason in classification metadata.

This guarantees that single-photo-with-music posts use image processing.

### 3) Route-Specific Analysis Pipelines

#### Image pipeline
Used for:
- native images
- `semantic_type=static_video_image`

Stages:
1. visual labels/description from image bytes (or static representative frame),
2. OCR from image payload,
3. face detection/identity linking from image payload,
4. metadata aggregation + comment generation.

#### Video pipeline
Used only for:
- `semantic_type=dynamic_video`

Stages:
1. video feature extraction (labels, shot/scenes, optional faces),
2. representative-frame extraction for OCR/face fallback if needed,
3. metadata aggregation (duration, scenes, objects, OCR summary),
4. comment generation from merged evidence.

## Extraction Model

### Core extracted signals
- Visual topics/labels
- OCR text + OCR blocks
- Face count and matched identities
- Video duration + scene/shot changes (dynamic video only)
- Content/objects/hashtags/mentions

### Normalized analysis fields
The final post analysis should consistently expose:
- `image_description`
- `topics`
- `face_summary`
- `ocr_text`, `ocr_blocks`
- `video_processing_mode`
- `video_static_detected`
- `video_duration_seconds`

## Comment Generation Integration

`Ai::PostCommentGenerationService` should consume normalized evidence, not raw media type.

Required evidence policy (current behavior to preserve):
- history ready
- face signal present
- OCR signal present

How media route affects comments:
- `image_pipeline` (including static-video-image):
  - comments are grounded on image description + OCR + face signals.
- `video_pipeline`:
  - comments use video-derived topics/scenes plus OCR/face signals.

Guardrails:
- if required evidence is missing, block generation with explicit reason codes,
- do not fallback to "video-only assumptions" when semantic type is static image.

## Operational Requirements

1. Single classifier source of truth.
- `media_classification` must be written once and reused by all steps.
2. No duplicate frame-change classification.
- downstream jobs should read persisted classification result.
3. Observability.
- structured logs for:
  - `media_classification.completed`
  - `media_classification.failed`
  - `analysis_route.selected`
4. Deterministic replay.
- re-analysis should preserve classification unless media blob changes.

## Recommended Rollout Plan

1. Add canonical `media_classification` metadata contract and classifier step.
2. Route pipeline jobs by `analysis_route` instead of blob MIME alone.
3. Remove duplicate frame-change execution in later steps.
4. Add tests:
   - image blob -> image route
   - single-photo-with-music video -> static-video-image -> image route
   - dynamic video -> video route
   - classifier failure fallback -> video route
5. Track route metrics to verify reduced false video routing.

## Acceptance Criteria

- A post with a video container but static visual frames is classified as `semantic_type=static_video_image`.
- That post is processed through the image pipeline and never requires full video labeling.
- Comment generation for static-video-image posts uses image-grounded evidence.
- Pipeline metadata clearly shows classification and selected route.

