# Instagram Client Facade Guidelines

Last updated: 2026-02-20

This document defines how `Instagram::Client` is structured and how new behavior should be added without reintroducing a monolith.

## Core Structure

### `Instagram::Client` (Facade)
`Instagram::Client` is the single entrypoint used by jobs/controllers and delegates feature logic to specialized modules/services.

Included modules and responsibilities:
- `Instagram::Client::BrowserAutomation`: Selenium driver/session bootstrap, cookie/localStorage persistence, authenticated browser lifecycle.
- `Instagram::Client::SessionRecoverySupport`: retry policy for recoverable browser disconnect/session-drop failures.
- `Instagram::Client::TaskCaptureSupport`: structured HTML/JSON/screenshot task captures for diagnostics.
- `Instagram::Client::CoreHelpers`: shared low-level helpers (waiters, normalization, parsing).
- `Instagram::Client::StoryApiSupport`: story/feed API adapters and story/media extraction.
- `Instagram::Client::SyncCollectionSupport`: conversation/story user discovery for sync workflows.
- `Instagram::Client::DirectMessagingService`: DM transport, messageability checks, API/UI fallback.
- `Instagram::Client::CommentPostingService`: post-comment API flow with UI fallback.
- `Instagram::Client::FollowGraphFetchingService`: followers/following/mutuals sync orchestration.
- `Instagram::Client::ProfileFetchingService`: profile details and eligibility enrichment.
- `Instagram::Client::FeedFetchingService`: profile/home feed acquisition and pagination.
- `Instagram::Client::FeedEngagementService`: feed capture and engagement orchestration.
- `Instagram::Client::StoryScraperService`: story traversal and story-level automation pipeline.
- `Instagram::Client::AutoEngagementSupport`: story/post auto-engagement workflow, AI suggestion orchestration, reply dedupe/history controls.
- `Instagram::Client::StoryNavigationSupport`: story tray targeting, context recovery, canonical story URL/reference handling, viewer stabilization.
- `Instagram::Client::MediaDownloadSupport`: facade-level adapter that delegates media fetch operations to `MediaDownloadService`.
- `Instagram::Client::StoryInteractionSupport`: UI/API comment/reply submission, reply capability checks, interaction state transitions.
- `Instagram::Client::StorySignalSupport`: image quality checks, ad detection heuristics, external profile-link signal extraction.
- `Instagram::Client::BrowserStateSupport`: shared browser state helpers (`logged_out_page?`, overlay dismissal, web storage read/write, JS click helpers).

### Story Scraper Decomposition
`StoryScraperService` is a composition module that exposes facade entrypoints and delegates implementation to smaller components:

- `Instagram::Client::StoryScraper::HomeCarouselSync` (`app/services/instagram/client/story_scraper/home_carousel_sync.rb`)
  - Owns end-to-end `sync_home_story_carousel!` workflow orchestration.
  - Handles traversal limits, per-story processing flow, skip/error recording, and completion telemetry.
- `Instagram::Client::StoryScraper::CarouselOpening` (`app/services/instagram/client/story_scraper/carousel_opening.rb`)
  - Owns first-story discovery/opening from home carousel, including fallback strategies and capture diagnostics.
- `Instagram::Client::StoryScraper::CarouselNavigation` (`app/services/instagram/client/story_scraper/carousel_navigation.rb`)
  - Owns "move to next story" logic and selector probing for resilient carousel progression.
- `Instagram::Client::StoryScraper::SyncStats` (`app/services/instagram/client/story_scraper/sync_stats.rb`)
  - Typed state carrier for sync counters (downloaded/analyzed/commented/skipped/failed metrics).
  - Replaces inline ad-hoc hash initialization to keep metric contracts explicit and reusable.

### Service Objects
Facade methods delegate multi-step dataset assembly and transport to dedicated services:
- `Instagram::Client::ProfileAnalysisDatasetService`
- `Instagram::Client::ProfileStoryDatasetService`
- `Instagram::Client::MediaDownloadService`

These services use dependency injection or narrow constructor dependencies to preserve testability and avoid hidden coupling.

### `InstagramProfileEvent`
The model stays persistence-centric and delegates orchestration via concerns:
- `InstagramProfileEvent::CommentGenerationCoordinator`
- `InstagramProfileEvent::Broadcastable`
- `InstagramProfileEvent::LocalStoryIntelligence`

## Interaction Model

### Auto-Engagement (Feed + Story)
1. Caller invokes `Instagram::Client#auto_engage_home_feed!`.
2. `FeedEngagementService` orchestrates high-level flow only.
3. `AutoEngagementSupport` selects candidate items and composes payloads.
4. `MediaDownloadSupport` delegates download I/O to `MediaDownloadService`.
5. `StoryInteractionSupport` performs API-first submission with UI fallback.
6. `StorySignalSupport` and `StoryNavigationSupport` provide gating signals/context normalization when needed.
7. `TaskCaptureSupport` records diagnostic state and stable status keys.

### Story Sync Path
1. Job/controller calls `Instagram::Client#sync_home_story_carousel!`.
2. `StoryScraperService` resolves implementation from `StoryScraper::HomeCarouselSync`.
3. `HomeCarouselSync` invokes:
   - `CarouselOpening` to enter viewer on first valid story.
   - `CarouselNavigation` for deterministic movement to next story.
4. `StoryNavigationSupport` and `StorySignalSupport` provide context extraction and skip heuristics.
5. `StoryInteractionSupport` owns reply eligibility + reply submission paths.
6. Shared supports (`TaskCaptureSupport`, `StoryApiSupport`, `CoreHelpers`) provide cross-cutting behavior.

## Guidelines for New Features

1. Keep `app/services/instagram/client.rb` facade-only:
   - public API entrypoints,
   - constants,
   - module composition.
2. Add new behavior in a dedicated module/service object, not directly in the facade file.
3. Use single-capability modules:
   - navigation/selectors,
   - transport/API calls,
   - AI/comment decision logic,
   - telemetry/capture.
4. For workflows combining 3+ collaborators, prefer a service object with injected dependencies.
5. Keep module methods private-first; expose only explicit facade entrypoints.
6. Preserve stable output/status contracts consumed by jobs/UI (reason codes, counters, payload keys).
7. Add or update tests in the nearest boundary:
   - module/service unit coverage,
   - facade integration behavior where orchestration changes.
8. Trigger decomposition review when a file exceeds ~400-500 lines or mixes more than one capability boundary.

## Scalability and Drift Prevention

1. Enforce dependency direction:
   - jobs/controllers -> facade,
   - facade -> domain modules/services,
   - modules -> shared supports (no reverse coupling).
2. Keep low-level I/O isolated:
   - HTTP/media transfer belongs in service objects,
   - Selenium selectors/navigation belongs in navigation modules.
3. Keep side-effect boundaries explicit:
   - persistence (`record_event!`, state updates),
   - network calls,
   - background job enqueues.
4. Keep telemetry centralized through `TaskCaptureSupport` and structured event payloads.
5. Prevent contract drift:
   - treat reason/status strings as API contracts,
   - version or document any required contract change.
6. Require refactor checkpoints in reviews:
   - responsibility map updated,
   - specs passing for affected boundaries,
   - architecture docs updated in the same PR.
