# Face, Identity Resolution, and Video Pipeline

Last updated: 2026-02-20

This document covers the face detection → embedding → matching → identity resolution pipeline, post-level face recognition, and all video processing services.

## Pipeline Overview

```
Media (image/video)
  ↓
FaceDetectionService          → detected faces, OCR, objects, labels
  ↓
FaceEmbeddingService          → face embeddings (128-d vectors)
  ↓
VectorMatchingService         → person matching via cosine similarity (pgvector)
  ↓
FaceIdentityResolutionService → primary/collaborator identity, username linking
  ↓
Persisted: InstagramStoryFace / InstagramPostFace → InstagramStoryPerson
```

## FaceDetectionService

File: `app/services/face_detection_service.rb`

Detects faces, extracts OCR text, and identifies objects in image media.

### Input/Output

- **Input**: `media_payload` — hash with `bytes` (raw image bytes)
- **Output**: hash with `faces`, `ocr_text`, `ocr_blocks`, `content_labels`, `object_detections`, `location_tags`, `mentions`, `hashtags`

### Detection Flow

1. Send image bytes to `Ai::LocalMicroserviceClient#detect_faces_and_ocr!`
2. Parse response: normalize face bounding boxes, landmarks, likelihoods
3. Filter faces by minimum confidence threshold (`MIN_FACE_CONFIDENCE = 0.3`)
4. Filter faces by valid bounding box dimensions
5. Deduplicate overlapping faces using IoU (Intersection over Union, threshold `0.45`)
6. Normalize OCR blocks and object detections from response payload

### Face Normalization

Each face is normalized to:
```ruby
{
  confidence: Float,        # detector confidence
  bounding_box: { x:, y:, width:, height: },
  landmarks: { ... },       # nose, eyes, mouth positions
  likelihoods: { ... },     # joy, sorrow, anger, etc.
  age_range: "20-30",       # estimated from age value
  gender: String            # if available
}
```

## FaceEmbeddingService

File: `app/services/face_embedding_service.rb`

Generates face embeddings for matching.

- Crops face region from source image using bounding box
- Sends cropped face to `Ai::LocalMicroserviceClient` embedding endpoint
- Returns 128-dimensional float vector
- Embedding version is tracked for compatibility

## VectorMatchingService

File: `app/services/vector_matching_service.rb`

Matches face embeddings against known `InstagramStoryPerson` records using cosine similarity.

### Matching Algorithm

1. Load candidate `InstagramStoryPerson` records for the profile
2. Compare input embedding against each candidate's `canonical_embedding`
3. Apply minimum similarity threshold (configurable, default varies by context)
4. Return best match with similarity score, or `nil` if no match exceeds threshold

### When a Match is Found

- Link the `InstagramStoryFace` / `InstagramPostFace` to the matched `InstagramStoryPerson`
- Update person's `canonical_embedding` (running average), `appearance_count`, `last_seen_at`

### When No Match is Found

- Create a new `InstagramStoryPerson` with the face's embedding as initial `canonical_embedding`
- Set `role: "secondary_person"` (promoted later by identity resolution)

## FaceIdentityResolutionService

File: `app/services/face_identity_resolution_service.rb`

Resolves face identities across stories and posts for a profile. Determines who the profile owner is, identifies collaborators, and links usernames to person clusters.

### Entry Points

- `resolve_for_post!(post:)` — called after post face analysis
- `resolve_for_story!(story:)` — called after story processing

Both delegate to `resolve_for_source!` with source-type routing.

### Resolution Algorithm

1. **Collect faces** from source (story faces or post faces)
2. **Collect usernames** from profile bio, post caption, OCR text, mentions, URLs
3. **Build participants** — group faces by linked `InstagramStoryPerson`
4. **Apply username links** — match extracted usernames to person clusters
5. **Compute profile face stats** — aggregate all faces across profile's stories and posts
6. **Promote primary identity** — the most frequently appearing face becomes `role: "primary_person"` (likely the profile owner)
7. **Build collaborator index** — identify recurring co-appearing people
8. **Update collaborator relationships** — write relationship metadata (`close_friend`, `frequent_collaborator`, `occasional_collaborator`)
9. **Persist results** — update `InstagramStoryPerson` metadata, face roles, profile-level face identity

### Primary Identity Promotion

A person is promoted to `primary_person` when:
- They have the highest total appearance count across all sources
- Their appearance count exceeds the threshold (currently 2+)
- They appear in significantly more sources than other people (~50% of total appearances)

### Collaborator Classification

Based on co-appearance count with the primary person:
- 5+ co-appearances → `close_friend`
- 3+ co-appearances → `frequent_collaborator`
- 1+ co-appearances → `occasional_collaborator`

## PostFaceRecognitionService

File: `app/services/post_face_recognition_service.rb`

Post-level face recognition pipeline. Wraps `FaceDetectionService` + `FaceEmbeddingService` + `VectorMatchingService` + `FaceIdentityResolutionService` for profile post context.

### Flow

1. Load post media bytes from Active Storage
2. Detect faces via `FaceDetectionService`
3. For each detected face: generate embedding, match against known people
4. Persist `InstagramPostFace` records
5. Run `FaceIdentityResolutionService.resolve_for_post!`
6. Write face recognition metadata to `post.metadata`

## Video Processing Services

### VideoFrameExtractionService

File: `app/services/video_frame_extraction_service.rb`

Extracts frames from video using FFmpeg.

- Configurable sample rate (frames per second)
- Outputs frames as JPEG bytes array
- Uses `ffmpeg -i input -vf fps=<rate> -f image2pipe` pipeline

### VideoAudioExtractionService

File: `app/services/video_audio_extraction_service.rb`

Extracts audio track from video using FFmpeg.

- Outputs WAV format for Whisper compatibility
- Uses `ffmpeg -i input -vn -acodec pcm_s16le -ar 16000 -ac 1` pipeline

### VideoFrameChangeDetectorService

File: `app/services/video_frame_change_detector_service.rb`

Classifies videos as static or dynamic based on frame-to-frame visual changes.

- Compares sequential frames using pixel difference metrics
- **Static video**: single image/slideshow with no significant visual changes → processed as single image
- **Dynamic video**: significant visual changes → processed with full frame extraction pipeline

### VideoMetadataService

File: `app/services/video_metadata_service.rb`

Probes video files for metadata using `ffprobe`.

- Extracts: duration, resolution, frame rate, codec, audio presence
- Used to determine processing strategy and store duration on `instagram_stories`

### VideoThumbnailService

File: `app/services/video_thumbnail_service.rb`

Generates thumbnail images from videos.

- Extracts a representative frame (typically at 1s or 25% of duration)
- Used for preview image generation (`GenerateStoryPreviewImageJob`, `GenerateProfilePostPreviewImageJob`)

### PostVideoContextExtractionService

File: `app/services/post_video_context_extraction_service.rb`

Full video context extraction for post analysis pipeline.

- Manages frame extraction → per-frame analysis → audio extraction → transcription
- Merges OCR, object, and topic signals across frames
- Builds normalized video summary for `post.metadata["video_processing"]`
- Integration point between video services and `ProcessPostVideoAnalysisJob`

## SpeechTranscriptionService

File: `app/services/speech_transcription_service.rb`

Local speech-to-text using OpenAI Whisper CLI.

- Checks for `whisper` CLI availability
- Transcribes extracted audio WAV files
- Returns transcript text for video content understanding
- Falls back gracefully when Whisper is not installed

## StoryProcessingService Integration

File: `app/services/story_processing_service.rb`

The `StoryProcessingService` is the primary consumer of face and video services for stories. See `docs/workflows/story-intelligence-pipeline.md` for the full story processing flow.

Key integration points:
- Calls `FaceDetectionService` for every story image/frame
- Calls `FaceEmbeddingService` + `VectorMatchingService` for each detected face
- Routes static vs dynamic video through `VideoFrameChangeDetectorService`
- Calls `VideoFrameExtractionService` + `VideoAudioExtractionService` for dynamic videos
- Calls `SpeechTranscriptionService` for audio tracks
- Calls `FaceIdentityResolutionService` at the end of processing
- Calls `StoryContentUnderstandingService` to build unified content structure
