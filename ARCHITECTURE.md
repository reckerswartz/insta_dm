# Instagram Application Architecture Guidelines

This document captures the current decomposition of large objects into smaller, composable units, with `Instagram::Client` acting as a facade and domain services/modules owning behavior.

## Core Structure

### `Instagram::Client` (Facade)
`Instagram::Client` remains the single entry point used by jobs/controllers, but it now composes focused modules instead of hosting all behavior directly.

Included modules and responsibilities:
- `Instagram::Client::BrowserAutomation`: Selenium driver/session bootstrap, cookie/localStorage persistence, and authenticated browser lifecycle.
- `Instagram::Client::SessionRecoverySupport`: retry policy for recoverable browser disconnect/session-drop failures.
- `Instagram::Client::TaskCaptureSupport`: structured HTML/JSON/screenshot task captures for diagnostics and observability.
- `Instagram::Client::CoreHelpers`: shared low-level helpers (waiters, normalization, cookie headers, parsing helpers).
- `Instagram::Client::StoryApiSupport`: story/feed API adapters and story/media extraction logic.
- `Instagram::Client::SyncCollectionSupport`: collection of conversation/story users used by sync/follow graph workflows.
- `Instagram::Client::DirectMessagingService`: DM transport, messageability checks, and UI/API fallback flow.
- `Instagram::Client::CommentPostingService`: post-comment API flow with UI fallback.
- `Instagram::Client::FollowGraphFetchingService`: followers/following/mutuals sync and persistence coordination.
- `Instagram::Client::ProfileFetchingService`: profile details and eligibility enrichment.
- `Instagram::Client::FeedFetchingService`: profile/home feed item acquisition and pagination.
- `Instagram::Client::FeedEngagementService`: feed capture and engagement orchestration.
- `Instagram::Client::StoryScraperService`: story carousel traversal and story-level automation pipeline.

### Service Objects

Facade methods delegate dataset assembly into dedicated service objects:
- `Instagram::Client::ProfileAnalysisDatasetService`: builds profile + posts analysis dataset.
- `Instagram::Client::ProfileStoryDatasetService`: builds profile + stories dataset (newly extracted from the facade).

Both services use dependency injection of callables (`method(...)`) to stay testable and avoid hidden coupling.

### `InstagramProfileEvent`
The model remains decomposed with concerns:
- `InstagramProfileEvent::CommentGenerationCoordinator`
- `InstagramProfileEvent::Broadcastable`
- `InstagramProfileEvent::LocalStoryIntelligence`

This keeps persistence-centric behavior in the model while orchestration/analysis is delegated.

## Interaction Model

1. Caller invokes facade API (`Instagram::Client.new(account: ...)`).
2. Facade routes work to a domain module (`DirectMessagingService`, `StoryScraperService`, etc.).
3. Domain modules use shared supports (`CoreHelpers`, `TaskCaptureSupport`, `SessionRecoverySupport`) and explicit service objects (`ProfileStoryDatasetService`, `ProfileAnalysisDatasetService`) where orchestration is multi-step.
4. Results return to jobs/controllers without leaking low-level Selenium/HTTP details.

## Guidelines for New Features

1. Add new behavior in a new module or service object, not directly in `instagram/client.rb`.
2. Keep `Instagram::Client` as a facade:
   - public API methods only;
   - orchestration delegation only;
   - avoid embedding feature logic.
3. For workflows that combine 3+ collaborators, prefer a service object class with injected collaborators.
4. Keep helper modules private-first: expose only intentional entry points.
5. If a module exceeds ~400 lines or owns multiple unrelated workflows, split by capability (e.g. `StoryApiSupport` vs `StoryReplySupport`).

## Scalability / Drift Prevention

1. Enforce architectural boundaries in code reviews:
   - no direct Selenium logic in jobs/controllers;
   - no new cross-domain coupling inside shared helpers.
2. Require targeted specs for each extraction:
   - keep behavior parity tests for facade APIs;
   - add unit specs for new service objects.
3. Prefer dependency injection over global lookups for new services.
4. Keep diagnostics centralized in `TaskCaptureSupport` to avoid ad-hoc logging patterns.
5. Update this document when adding a module/service so structure stays discoverable.
