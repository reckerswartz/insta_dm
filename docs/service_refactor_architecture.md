# Service Refactor Architecture Guide

## Goals
- Reduce controller and utility-class complexity.
- Isolate responsibilities into small service objects.
- Preserve behavior while making feature changes safer.
- Keep architecture aligned with SOLID and Rails service-object patterns.

## New Structure

### `StoryArchive` shared module
- `StoryArchive::MediaPreviewResolver`
  - Owns story media preview and static-video detection logic.
  - Reused by account controller serializers, profile event payload builder, and ops audit log builder.
  - Eliminates duplicated parsing rules.

### `InstagramAccounts` service layer
- `InstagramAccounts::DashboardSnapshotService`
  - Aggregates account dashboard data for `InstagramAccountsController#show`.
  - Delegates skip diagnostics to its own service.
- `InstagramAccounts::SkipDiagnosticsService`
  - Aggregates skip/failure reasons and classifies them.
- `InstagramAccounts::StoryArchiveQuery`
  - Encapsulates pagination/date filtering query for story archive items.
- `InstagramAccounts::StoryArchiveItemSerializer`
  - Serializes story archive events, including media URLs, ownership fields, and LLM summary fields.
- `InstagramAccounts::LlmQueueInspector`
  - Sidekiq-specific queue size and stale-job checks.
- `InstagramAccounts::LlmCommentRequestService`
  - Orchestrates comment status polling, stale-job recovery, and queueing.
- `InstagramAccounts::TechnicalDetailsPayloadService`
  - Builds technical details payload and timeline for a story event.

### `InstagramProfiles` service layer
- `InstagramProfiles::TabulatorParams`
  - Parses remote filter/sorter payloads and tri-state booleans.
- `InstagramProfiles::ProfilesIndexQuery`
  - Encapsulates profile index filtering/sorting/pagination logic.
- `InstagramProfiles::EventsQuery`
  - Encapsulates profile event filtering/sorting/pagination logic.
- `InstagramProfiles::TabulatorProfilesPayloadBuilder`
  - Builds JSON payload for profile table API responses.
- `InstagramProfiles::TabulatorEventsPayloadBuilder`
  - Builds JSON payload for profile events table API responses.
- `InstagramProfiles::MutualFriendsResolver`
  - Resolves profile mutuals through `Instagram::Client`.
- `InstagramProfiles::ShowSnapshotService`
  - Aggregates `show` page data and delegates mutual resolution.

## Controller Responsibilities After Refactor
- `InstagramAccountsController`
  - HTTP input/output only.
  - Delegates data loading/serialization/workflow decisions to `InstagramAccounts::*` services.
- `InstagramProfilesController`
  - HTTP input/output only.
  - Delegates querying/payload assembly/show-page aggregation to `InstagramProfiles::*` services.

## Interaction Model

### Account dashboard (`InstagramAccountsController#show`)
1. Controller invokes `DashboardSnapshotService`.
2. Service loads issues, metrics, failures, audit entries, queue summary, and skip diagnostics.
3. Controller renders with returned snapshot hash.

### Story archive endpoint (`#story_media_archive`)
1. Controller invokes `StoryArchiveQuery`.
2. Controller maps query rows through `StoryArchiveItemSerializer`.
3. Serializer uses `StoryArchive::MediaPreviewResolver`.

### LLM comment endpoint (`#generate_llm_comment`)
1. Controller invokes `LlmCommentRequestService`.
2. Service checks ownership/status, handles stale jobs through `LlmQueueInspector`, and enqueues jobs when needed.
3. Controller renders service result payload/status.

### Profile index/events (`InstagramProfilesController#index/events`)
1. Controller invokes query service (`ProfilesIndexQuery` or `EventsQuery`).
2. Controller invokes payload builder (`TabulatorProfilesPayloadBuilder` or `TabulatorEventsPayloadBuilder`).
3. Payload builders use shared preview resolver where needed.

### Profile show (`#show`)
1. Controller invokes `ShowSnapshotService`.
2. Service computes counts/history state/latest event and mutuals via `MutualFriendsResolver`.
3. Controller assigns view ivars from snapshot.

## Guidelines For Adding New Features
- Add behavior to a dedicated service if it combines:
  - Query logic + transformation logic.
  - Cross-cutting metadata parsing.
  - Background job orchestration/state transitions.
- Keep controllers thin:
  - Validate inputs.
  - Delegate to one primary service per action.
  - Render service outputs.
- Prefer composition over large inheritance trees.
- Inject collaborators (client/inspector/etc.) as constructor args for testability.

## Best Practices To Prevent Architectural Drift
- Keep single reason to change per service:
  - Query services only query/sort/filter.
  - Payload builders only serialize.
  - Orchestrators coordinate state transitions and side effects.
- Reuse shared utilities (`StoryArchive::MediaPreviewResolver`) instead of copying parsing logic.
- Add service specs for each new service boundary before expanding controllers.
- Keep public return contracts explicit (`Result` structs or stable hashes).
- Avoid adding business logic back into controllers/views/jobs.
- For high-risk flows (LLM state transitions, queue logic), test success + stale/retry/error branches.
- Track file growth:
  - If a class exceeds ~200-300 lines or mixes query/serialization/orchestration, split it.

## Verification Added In This Refactor
- New service specs:
  - `spec/services/instagram_accounts/llm_comment_request_service_spec.rb`
  - `spec/services/instagram_accounts/skip_diagnostics_service_spec.rb`
  - `spec/services/instagram_accounts/story_archive_query_spec.rb`
  - `spec/services/instagram_profiles/profiles_index_query_spec.rb`
  - `spec/services/story_archive/media_preview_resolver_spec.rb`
- Existing request specs confirmed for profile pages:
  - `spec/requests/instagram_profiles_mutual_friends_spec.rb`
  - `spec/requests/instagram_profiles_captured_posts_person_links_spec.rb`
