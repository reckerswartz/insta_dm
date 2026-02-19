# Unofficial Instagram Messaging App (Rails + Selenium)

This project provides a Rails UI to:
- authenticate to Instagram once (manual login or cookie import),
- sync followers + following (primary user source),
- show who follows you back (mutuals),
- extract/store profile pictures for table display,
- message users individually with message history.

## Important note
Use this only for accounts and usage patterns you are authorized to automate. Instagram UI/API behavior changes often and may restrict or block automated access.

## Stack
- Ruby on Rails 8
- PostgreSQL (primary DB)
- pgvector (vector similarity in Postgres)
- Sidekiq + Redis (background jobs)
- Selenium WebDriver
- Google Chrome + ChromeDriver

## Setup

```bash
docker compose up -d postgres redis
bundle install
bin/rails db:prepare
bin/dev
```

Open `http://localhost:3000`.

## Testing (RSpec + Parallel + VCR)

This project uses RSpec as the primary test framework.

Run all specs:

```bash
bundle exec rspec
```

Run specs in parallel (auto-prepares test DB shards):

```bash
bin/parallel_rspec
```

Control worker count:

```bash
RSPEC_WORKERS=4 bin/parallel_rspec
```

### Selenium UI verification (responsive smoke)

Run the Selenium UI verifier to exercise navigation/actions and capture temporary screenshots for multiple viewports:

```bash
ruby script/ui_selenium_verify.rb
```

Useful options:

```bash
# limit actions per page and target specific viewports/routes
UI_VERIFY_MAX_ACTIONS=2 UI_VERIFY_VIEWPORTS=mobile,portrait,desktop,4k UI_VERIFY_ROUTES=/,/instagram_profiles ruby script/ui_selenium_verify.rb

# disable deep Tabulator pagination/state/interaction verification if needed
UI_VERIFY_TABLE_CHECKS=0 ruby script/ui_selenium_verify.rb
```

Artifacts are written to:
- `tmp/ui_verify/<timestamp>/report.json`
- `tmp/ui_verify/<timestamp>/*.png`

### VCR recording and replay

Third-party HTTP responses are recorded with VCR and replayed during tests.

- Cassette path: `spec/vcr_cassettes/<scope>/...`
- Default scope: `test`
- Default record mode:
  - local: `once`
  - CI: `none`

Common usage:

```bash
# replay only (fail if cassette missing)
VCR_RECORD_MODE=none bundle exec rspec

# record new interactions only when cassette is missing
VCR_RECORD_MODE=once bundle exec rspec

# re-record all interactions
VCR_RECORD_MODE=all bundle exec rspec
```

To separate cassette sets by environment-like scope (for local refresh workflows):

```bash
VCR_CASSETTE_SCOPE=development VCR_RECORD_MODE=all bundle exec rspec
VCR_CASSETTE_SCOPE=production VCR_RECORD_MODE=all bundle exec rspec
```

Default local infrastructure:
- Postgres: `127.0.0.1:5432` (`postgres/postgres`)
- Redis: `127.0.0.1:6379`

Useful env vars:
- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`
- `REDIS_URL`, `REDIS_CACHE_URL`, `REDIS_CABLE_URL`

If you are migrating an existing local SQLite setup, recreate DBs on Postgres:

```bash
bin/rails db:drop db:create db:migrate
```

Recommended stable setup on Ubuntu/WSL:

## Encrypted app configuration (Rails credentials)

This app now reads Instagram settings from encrypted Rails credentials via `dig`, for example:
- `Rails.application.credentials.dig(:instagram, :username)`
- `Rails.application.credentials.dig(:instagram, :headless)`

Set values with:

```bash
bin/rails credentials:edit
```

Example credentials payload:

```yml
instagram:
  username: my_user
  headless: true
```

Set `headless: false` only when doing manual interactive troubleshooting. Manual login always opens a visible browser window regardless.

## AI providers (local-only)

The app uses a local AI microservice architecture:
- Local AI provider is managed through the AI microservice
- All AI processing runs locally using Ollama models
- Outputs are consolidated into one polymorphic table (`AiAnalysis`) for profiles and posts
- No external/cloud AI services are used or supported

### Local AI microservice setup

Start the local AI microservice:

```bash
cd ai_microservice
./setup.sh
./start_microservice.sh
```

The microservice provides:
- Face detection and recognition
- OCR (text extraction)
- Image analysis and understanding
- Text generation for comments
- Embedding generation

### Configure local AI

The local provider can be configured in the database or via Rails console:

```bash
# In Rails console
AiProviderSetting.where(provider: 'local').first_or_create.update(
  config: { ollama_model: 'mistral:7b' },
  enabled: true
)
```

### Analysis behavior

- Profile analysis and post analysis run on the `ai` queue.
- The runner skips provider calls when the same media fingerprint has already been analyzed (`AiAnalysis` cache reuse).
- All processing uses the local AI microservice.
- Post analysis supports both image and video paths.
- The system includes a dedicated text-generation service to generate contextual comments from profile/post/story context.

### Materialized insight tables

AI output is now stored in two layers:
1. Raw run record: `AiAnalysis` (provider/model/prompt/response/analysis JSON)
2. Query-friendly tables for app logic:
- `instagram_profile_insights`
- `instagram_profile_message_strategies`
- `instagram_profile_signal_evidences`
- `instagram_post_insights`
- `instagram_post_entities`

`ai_analyses` also stores quality/coverage fields:
- `input_completeness_score`
- `confidence_score`
- `evidence_count`
- `signals_detected_count`
- `prompt_version`
- `schema_version`

## Active Record encryption bootstrap

Use the built-in Rails key generator and auto-write keys into encrypted credentials:

```bash
bin/rails app:security:bootstrap_encryption
```

The task runs `db:encryption:init`, parses generated keys, and populates:
- `active_record_encryption.primary_key`
- `active_record_encryption.deterministic_key`
- `active_record_encryption.key_derivation_salt`

`bin/setup` runs this task automatically.

Example:

```bash
bin/rails server
```

## Authentication options

### 1) Manual one-time login
1. Click **Manual Browser Login (3 min)**.
2. A Chrome window opens to Instagram login.
3. Complete login (including 2FA if prompted).
4. Once `sessionid` cookie exists, app stores all cookies encrypted in DB.

### 2) Cookie import
Paste cookie JSON in **Import cookies JSON**.
Expected structure is an array of cookie objects:

```json
[
  {
    "name": "sessionid",
    "value": "...",
    "domain": ".instagram.com",
    "path": "/",
    "secure": true
  }
]
```

## How to transfer browser cookies
1. Login manually to Instagram in your normal browser.
2. Open DevTools -> Application/Storage -> Cookies -> `https://www.instagram.com`.
3. Export cookies as JSON (or copy values and build JSON with `name`, `value`, `domain`, `path`, optional `secure`, `expiry`).
4. Paste into **Import cookies JSON** and submit.
5. Optional: use **Export Stored Cookies** to back up what Rails is using.

## Main workflow
1. Configure username and authenticate.
2. Click **Sync Followers/Following (Background)**.
3. Wait for the in-app notification that the sync completed.
4. Browse/search the **Profiles Data Table** (followers, following, mutuals).
5. Open a profile row to view message history and queue a message.

### Profile action history

Each profile now has a DB-backed action history (`InstagramProfileActionLog`) for actions such as:
- fetch profile details
- verify messageability
- AI profile analysis
- avatar sync

Each entry stores action, status (`queued/running/succeeded/failed`), timestamps, and optional logs/error metadata.

### Enhanced AI profile analysis flow

When you click **Analyze Profile** on a profile page, the job now:
1. Navigates to the user profile and fetches profile details (name/bio/profile image URL).
2. Collects all available profile posts (image posts are downloaded to Active Storage).
3. Downloads post images locally via Active Storage.
4. Captures comments (via media comments API with preview fallback) and likes metadata for each stored post.
5. Sends profile + stored post data to the active AI provider for analysis.

Stored tables for this flow:
- `instagram_profile_posts` (one row per captured post)
- `instagram_profile_post_comments` (captured comments per post)

Each captured profile post supports on-demand per-image AI analysis:
- route: `POST /instagram_profiles/:instagram_profile_id/instagram_profile_posts/:id/analyze`
- stores `image_description` + multiple `comment_suggestions` on the post record for modal display/reuse.

### Accumulated demographics enrichment

Profile analysis now includes a second-pass JSON aggregation step:
- combines current + historical `AiAnalysis` outputs for the profile,
- combines analyzed JSON from captured profile posts and linked feed posts,
- runs a structured aggregation service (`Ai::ProfileDemographicsAggregator`) to infer missing age/gender/location with confidence,
- writes consolidated inferred demographics to profile fields (`ai_estimated_*`) when missing or when confidence improves,
- writes post-level inferred demographics into each post `analysis["inferred_demographics"]` when relevant and missing.

This allows demographic assumptions to improve incrementally over time as more post/profile analysis JSON accumulates.

AI estimate fields saved on `instagram_profiles`:
- `ai_estimated_age`, `ai_age_confidence`
- `ai_estimated_gender`, `ai_gender_confidence`
- `ai_estimated_location`, `ai_location_confidence`
- `ai_persona_summary`, `ai_last_analyzed_at`

### Post comment generation (description-first)

For post analysis, the system now:
1. Generates/stores a visual `image_description` first (from Vision output).
2. Uses that description to generate multiple Gen Z-style comment suggestions.
3. Persists both into `instagram_post_insights` (`image_description`, `comment_suggestions`) so you can choose before posting.

## Current heuristics and limitations
- Profile discovery is from followers/following dialogs (plus inbox parsing to mark existing threads as messageable).
- Message eligibility is stored as the latest known value; `can_message` may be `Unknown` until verified or implied by an inbox thread.
- UI selectors can break whenever Instagram changes frontend markup.
- Background jobs run via Sidekiq (development + production). `bin/dev` starts both the web server and Sidekiq worker.

## Background processing (Sidekiq + cron)

This app uses Sidekiq + Redis, with recurring jobs loaded by `sidekiq-cron` from `config/sidekiq_schedule.yml`.

Key commands:

```bash
# Web + jobs in development
bin/dev

# Jobs only
bin/jobs
```

Sidekiq worker configuration is in `config/sidekiq.yml`.

### Automated feed/story engagement cron

Recurring job entries now include:
- `EnqueueFeedAutoEngagementForAllAccountsJob` -> `AutoEngageHomeFeedJob`

Flow for each authenticated account:
1. Open Instagram home with Selenium.
2. Optionally open first visible story, freeze/hold it, download media, store profile event history, analyze image, generate comments, post first suggestion, verify story does not auto-advance before/after posting.
3. Scan image posts in home feed, download each image, store profile history event with `download_link` + original size metadata, analyze, generate engagement comments, and post the first suggestion.
4. Capture per-step debug artifacts in `log/instagram_debug/YYYYMMDD/*` (HTML, JSON metadata, screenshot PNG).

### Admin dashboards

- Jobs console (recommended): `http://localhost:3000/admin/background_jobs`
  - Unified view of Mission Control access + Sidekiq/Solid Queue state + app failure logs
  - Jobs/failures are categorized as `profile`, `account`, or `system`
- Mission Control Jobs UI: `http://localhost:3000/admin/jobs`
  - Authentication is disabled for now to keep setup simple

Admin auth behavior:
- If `credentials.admin` / `ADMIN_USER`+`ADMIN_PASSWORD` are not set, admin pages remain open.
- If both username and password are set, HTTP Basic auth is enforced.

To protect admin pages, set one of:
- `credentials.admin.user` / `credentials.admin.password`
- `ADMIN_USER` / `ADMIN_PASSWORD`

Failures are persisted to `BackgroundJobFailure` whenever a job raises.

## Debug captures for sync tasks

For easier debugging, each sync task writes page captures with timestamp + task name:
- HTML snapshot: `log/instagram_debug/YYYYMMDD/<timestamp>_<task_name>_<status>.html`
- Metadata JSON: `log/instagram_debug/YYYYMMDD/<timestamp>_<task_name>_<status>.json`

Captured tasks currently include:
- conversation user collection
- followers collection
- following collection

Metadata includes timestamp, task name, account username, current URL, page title, and error details when a task fails.

## DM sending troubleshooting

If queued messages fail with `websocket_tls_error ERR_CERT_AUTHORITY_INVALID`, Chrome cannot establish a trusted TLS connection to Instagram chat endpoints (`gateway.instagram.com` / `edge-chat.instagram.com`).

Fix options:
- Preferred: trust/install the correct root CA in the host OS + Chrome profile (common in corp proxy/intercepted TLS setups).
- Local debugging only: run with `INSTAGRAM_CHROME_IGNORE_CERT_ERRORS=true` to allow Selenium Chrome to bypass certificate validation.

## Story intelligence pipeline (local-first)

The app now persists each downloaded story into `instagram_stories` and runs a background processing pipeline:

1. `StoryIngestionService` creates/updates `InstagramStory` and enqueues `StoryProcessingJob`.
2. `StoryProcessingService` runs:
- `FaceDetectionService` (local face detection + OCR + landmarks + labels)
- `FaceEmbeddingService` (local embedding service)
- `VectorMatchingService` (recurring person matching by cosine similarity)
- `VideoFrameExtractionService` (FFmpeg frame sampling for video stories)
- `VideoAudioExtractionService` (FFmpeg audio extraction for video stories)
- `SpeechTranscriptionService` (local Whisper CLI transcription when available)
- `StoryContentUnderstandingService` (unified content structure for image/video)
- `UserProfileBuilderService` (posting patterns, location trends, recurring co-appearances, topic/sentiment trends)

New tables:
- `instagram_stories`
- `instagram_story_people`
- `instagram_story_faces`
- `instagram_profile_behavior_profiles`

Embeddings are stored in PostgreSQL + pgvector vector columns for ANN search.

### Video support details

- Active Storage `instagram_stories.media` now supports both image and video.
- Video duration is stored in `instagram_stories.duration_seconds`.
- FFmpeg/ffprobe are used for frame/audio processing and metadata probing.
- Whisper CLI (`whisper`) is used for local speech-to-text when installed.

Unified content object is saved under `story.metadata["content_understanding"]`:

```json
{
  "objects": [],
  "faces": 0,
  "locations": [],
  "ocr_text": "",
  "transcript": "",
  "sentiment": "neutral",
  "topics": []
}
```

### Messaging integration policy

- Auto-replies require an official messaging endpoint configured through:
  - `OFFICIAL_MESSAGING_API_URL`
  - `OFFICIAL_MESSAGING_API_TOKEN`
- If official messaging is not configured, story auto-reply is skipped with reason `official_messaging_not_configured`.

## Suggested next improvements
- Capture screenshots + structured logs for failed recipients.
- Add a per-recipient message template engine and dry-run mode.
