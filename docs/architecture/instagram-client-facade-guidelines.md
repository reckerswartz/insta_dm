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

### Service Objects
Facade methods delegate multi-step dataset assembly to dedicated services:
- `Instagram::Client::ProfileAnalysisDatasetService`
- `Instagram::Client::ProfileStoryDatasetService`

Both services use dependency injection of callables (`method(...)`) to preserve testability and avoid hidden coupling.

### `InstagramProfileEvent`
The model stays persistence-centric and delegates orchestration via concerns:
- `InstagramProfileEvent::CommentGenerationCoordinator`
- `InstagramProfileEvent::Broadcastable`
- `InstagramProfileEvent::LocalStoryIntelligence`

## Interaction Model

1. Caller invokes facade API (`Instagram::Client.new(account: ...)`).
2. Facade routes to domain module/service (`DirectMessagingService`, `StoryScraperService`, etc.).
3. Domain modules reuse shared supports (`CoreHelpers`, `TaskCaptureSupport`, `SessionRecoverySupport`).
4. Results return to jobs/controllers without exposing low-level Selenium/HTTP internals.

## Guidelines for New Features

1. Add feature behavior in a new module or service object, not directly in `app/services/instagram/client.rb`.
2. Keep `Instagram::Client` as orchestration-only public API.
3. For workflows combining 3+ collaborators, prefer a service object with injected collaborators.
4. Keep helper modules private-first; expose only explicit entrypoints.
5. If a module grows beyond one capability boundary, split by concern.

## Scalability and Drift Prevention

1. Enforce boundaries in reviews:
   - no direct Selenium logic in jobs/controllers,
   - no cross-domain coupling in shared helpers.
2. Require targeted tests for each extraction/refactor:
   - behavior parity around facade entrypoints,
   - unit coverage for new services.
3. Prefer dependency injection over global lookups.
4. Keep diagnostics capture centralized in `TaskCaptureSupport`.
5. Update this document when adding/removing facade modules.
