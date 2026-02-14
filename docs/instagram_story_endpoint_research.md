# Instagram Story Endpoint Research (Selenium Network Payload)

Last updated: 2026-02-14

## Goal
Identify stable browser/network endpoints for story discovery so story processing does not depend on fragile HTML carousel parsing.

## Data Source
- Selenium performance logs already captured by the app in `log/instagram_debug/**/*.json`.
- These logs are produced by `Instagram::Client#capture_task_html` with Chrome `performance` logging enabled.
- Aggregation task: `bin/rake story_debug:network_endpoints`.

## Key Finding
Yes, Instagram web calls API endpoints that provide story tray and reel data in structured form (including user context), and these can be used to drive a username-first workflow.

## Story-Relevant Browser Endpoints (Observed)
From captured `Network.requestWillBeSentExtraInfo` and `Network.responseReceived` entries:

1. `POST /graphql/query`
- Friendly name: `PolarisStoriesV3TrayContainerQuery`
- Root field: `xdt_api__v1__feed__reels_tray`
- Purpose: loads story tray (ordered list of story owners on home).

2. `POST /graphql/query`
- Friendly name: `PolarisStoriesV3ReelPageGalleryPaginationQuery`
- Root field: `xdt_api__v1__feed__reels_media__connection`
- Purpose: loads/extends story items for the currently opened reel/user.

3. `POST /graphql/query`
- Friendly name: `PolarisStoriesV3ReelPageGalleryQuery`
- Root field: `xdt_viewer`
- Purpose: initial reel page payload when opening a story page.

4. `POST /graphql/query`
- Friendly name: `PolarisStoriesV3SeenMutation`
- Root field: `xdt_api__v1__stories__reel__seen`
- Purpose: marks story seen as user advances through stories.

5. `POST /graphql/query`
- Friendly name: `PolarisStoriesV3AdsPoolQuery`
- Root field: `xdt_injected_story_units`
- Purpose: story ads injection pool (important for ad filtering logic).

6. `POST /graphql/query`
- Friendly name: `usePolarisStoriesV3LikeMutationLikeMutation`
- Root field: `xdt_api__v1__story_interactions__send_story_like`
- Purpose: story like reaction interaction.

## Additional Direct API Endpoints Used by Current App (Non-browser `Net::HTTP`)
These are already used in `app/services/instagram/client.rb`:

1. `GET /api/v1/users/web_profile_info/?username=<username>`
- Resolve user metadata and `user_id`.

2. `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`
- Structured story media for a user (items with image/video URLs, timestamps).

3. `GET /api/v1/feed/user/<user_id>/?count=<n>[&max_id=...]`
- Profile feed pagination (posts).

## Recommended Username-First Story Flow
1. Fetch story tray list from `PolarisStoriesV3TrayContainerQuery` (`xdt_api__v1__feed__reels_tray`).
2. Extract ordered usernames/user IDs from response payload.
3. For each username:
- Open `https://www.instagram.com/<username>/` or `https://www.instagram.com/stories/<username>/` in a new tab.
- Fetch story media via reel endpoint (`xdt_api__v1__feed__reels_media__connection` or fallback `/api/v1/feed/reels_media/?reel_ids=`).
- Reuse existing download/analyze/process pipeline.

## API Indicators For Reshared/External-Attribution Stories
From captured reel item payloads (`/api/v1/feed/reels_media`), these fields are reliable skip signals when we want original-owner stories only:

- `story_feed_media` present and non-empty
  - typically indicates an embedded/shared feed media sticker (often another profile's post/reel)
- `media_attributions_data` present and non-empty
- `reel_mentions` present and non-empty
- `is_reshare_of_text_post_app_media_in_ig == true`
- `is_tagged_media_shared_to_viewer_profile_grid == true`
- `should_show_author_pog_for_tagged_media_shared_to_profile_grid == true`
- owner mismatch (`item.owner.id` != reel owner user id)

Implementation status:
- Story extraction now stores API attribution flags per story item.
- Story processing skips these items before download/analyze/reply when attribution flags indicate external/reshared content.

Local sample note (workspace debug captures):
- Scan date: 2026-02-14
- Files scanned: 32 (`tmp/story_reel_debug/*.json`)
- Story items scanned: 66
- `story_feed_media` present: 9 items
- `media_attributions_data`, `reel_mentions`, `is_reshare_of_text_post_app_media_in_ig` were present but empty/false in this sample set.

## Why This Is Better Than HTML Parsing
- Uses structured payload contracts and explicit query identities (`x-fb-friendly-name`, `x-root-field-name`).
- Preserves ordering from story tray without relying on unstable CSS selectors.
- Supports resilient fallback between browser GraphQL and direct `/api/v1/feed/reels_media`.

## Evidence Pointers
Sample captured files containing story query signatures:
- `log/instagram_debug/20260213/20260213T004201.665Z_home_story_sync_home_loaded_ok.json`
- `log/instagram_debug/20260214/20260214T192041.739Z_home_story_sync_after_next_click_ok.json`
- `log/instagram_debug/20260212/20260212T142354.492Z_dm_open_profile_ok.json`

These contain headers such as:
- `x-fb-friendly-name: PolarisStoriesV3TrayContainerQuery`
- `x-root-field-name: xdt_api__v1__feed__reels_tray`

## Re-run Analysis
```bash
bin/rake story_debug:network_endpoints
```

Output:
- `tmp/story_debug_reports/story_network_endpoints_<timestamp>.json`

## Implementation Status In Code
- Endpoint-first media resolution is now wired into carousel story processing in `app/services/instagram/client.rb`.
- Method `resolve_story_media_for_current_context` now tries:
  1) `web_profile_info` to get user id
  2) `feed/reels_media` to get story media URL for the current `story_id`
  3) DOM extraction only as fallback when API matching is ambiguous or unavailable
- This keeps Selenium for navigation/interactions, but story media download URLs come from API whenever possible.
