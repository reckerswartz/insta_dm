# Instagram Extraction Audit (HTML vs API)

Last updated: 2026-02-14

## Scope
This audit maps extraction and interaction actions in the app to:
- current implementation status (API-first, API+fallback, or UI-only)
- primary endpoints observed/used
- remaining HTML/UI dependencies
- where retryable reply/message permissions are persisted

## Permission State Persistence
Reply and message permissions are now stored separately on `instagram_profiles`:
- Story reply state:
  - `story_interaction_state`
  - `story_interaction_reason`
  - `story_interaction_checked_at`
  - `story_interaction_retry_after_at`
  - `story_reaction_available`
- DM state:
  - `dm_interaction_state`
  - `dm_interaction_reason`
  - `dm_interaction_checked_at`
  - `dm_interaction_retry_after_at`
- Shared legacy compatibility:
  - `can_message`
  - `restriction_reason`

Current retry behavior:
- Story replies: when unavailable, retry window is set (`STORY_INTERACTION_RETRY_DAYS`, currently 3 days).
- DM: unavailable sets retry window (403 -> 3 days, other failures -> shorter retry windows).

## Cron Jobs (sidekiq_schedule.yml) and Extraction Paths

1. `story_auto_reply_all_accounts` -> `EnqueueStoryAutoRepliesForAllAccountsJob` -> `SyncInstagramProfileStoriesJob`
- Status: API-first
- Data source: `fetch_profile_story_dataset!`
- Endpoints:
  - `GET /api/v1/users/web_profile_info/?username=<username>`
  - `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`
- HTML dependency: none for core story list/media extraction (debug HTML snapshots still captured only for diagnostics)

2. `feed_auto_engagement_all_accounts` -> `AutoEngageHomeFeedJob` -> `auto_engage_home_feed!`
- Status: API-first with UI interaction fallback
- Endpoints:
  - `GET /api/v1/feed/timeline/` (feed items)
  - `GET /api/v1/users/web_profile_info/` + `GET /api/v1/feed/reels_media/` (story media)
  - `POST /api/v1/media/<media_id>/comment/` (post comments)
- HTML/UI dependency:
  - opening story viewer, playback, and fallback comment posting remain UI-dependent

3. `profile_recent_posts_scan_all_accounts` -> `SyncRecentProfilePostsForProfileJob`
- Status: API-first
- Data source: `Instagram::ProfileAnalysisCollector` + `fetch_profile_analysis_dataset!`
- Endpoints:
  - `GET /api/v1/users/web_profile_info/`
  - `GET /api/v1/feed/user/<user_id>/`
  - `GET /api/v1/media/<media_id>/comments/` (with browser-context fallback for some sessions)
- HTML dependency: fallback comment enrichment via browser endpoint execution if direct HTTP misses

4. `follow_graph_sync_all_accounts` -> `SyncFollowGraphJob` -> `sync_follow_graph!`
- Status: API-first with UI fallback
- Endpoints:
  - `GET /api/v1/direct_v2/inbox/`
  - `GET /api/v1/feed/reels_tray/`
  - `GET /api/v1/friendships/<user_id>/followers/`
  - `GET /api/v1/friendships/<user_id>/following/`
- HTML dependency: follower/following modal scraping fallback if API access fails

5. `profile_refresh_all_accounts` -> `SyncNextProfilesForAccountJob` -> `FetchInstagramProfileDetailsJob`
- Status: API-first with UI fallback
- Endpoints:
  - `GET /api/v1/users/web_profile_info/`
  - `GET /api/v1/feed/user/<user_id>/`
  - DM verification API path: `POST /api/v1/direct_v2/create_group_thread/`
- HTML dependency: profile-page fallback parsing and UI messageability fallback if API cannot determine

## Major Workflows and Current State

1. Conversation users (`collect_conversation_users`)
- Status: API-first
- Endpoint: `GET /api/v1/direct_v2/inbox/`
- Fallback: inbox page HTML parsing (`verifyContactRowExists` payload segments)

2. Story tray users (`collect_story_users`)
- Status: API-first
- Endpoint: `GET /api/v1/feed/reels_tray/`
- Fallback: home page story anchors and regex extraction

3. Follow graph (`collect_follow_list`)
- Status: API-first
- Endpoint: `GET /api/v1/friendships/<user_id>/(followers|following)/`
- Fallback: followers/following modal DOM scrolling extraction

4. Home feed item discovery (`extract_feed_items_from_dom`)
- Status: API-first
- Endpoint: `GET /api/v1/feed/timeline/`
- Fallback: DOM extraction from `/p/` and `/reel/` links

5. Profile details (`fetch_profile_details_from_driver`)
- Status: API-first
- Endpoints:
  - `GET /api/v1/users/web_profile_info/`
  - `GET /api/v1/feed/user/<user_id>/`
- Fallback: profile HTML parsing

6. Profile messageability (`verify_messageability!`, `fetch_eligibility`)
- Status: API-first
- Endpoint: `POST /api/v1/direct_v2/create_group_thread/`
- Logic: if thread can be created/resolved, profile is messageable
- Fallback: UI CTA/composer checks

7. DM send (`send_message_to_user!`, `send_messages!`)
- Status: API-first with UI fallback
- Endpoints:
  - `POST /api/v1/direct_v2/create_group_thread/`
  - `POST /api/v1/direct_v2/threads/broadcast/text/`
- Fallback: open DM composer and send via UI

8. Story reply capability precheck (`story_reply_capability_from_api`)
- Status: API-first precheck + UI fallback
- Endpoint: `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`
- Signal: story item `can_reply`
- Fallback: UI reply-box detection

9. Story reply send (`post_story_reply_via_api!`)
- Status: API-first
- Endpoints:
  - `POST /api/v1/direct_v2/create_group_thread/`
  - `POST /api/v1/direct_v2/threads/broadcast/reel_share/`
- Fallback: UI story reply submission path remains available elsewhere

10. Post comment send (`post_comment_to_media!`)
- Status: API-first with UI fallback
- Endpoint: `POST /api/v1/media/<media_id>/comment/`
- Fallback: UI comment composer click/submit

11. Home story carousel sync (`sync_home_story_carousel!`)
- Status: Hybrid (UI navigation + API extraction)
- API usage:
  - story media resolution from reels API
  - reply capability precheck from story item `can_reply`
- UI dependency:
  - opening the first story
  - moving to next story in carousel
  - viewer state/context extraction for navigation

## Browser-Network Endpoints Observed for Stories (GraphQL/Web)
Observed via performance logs and documented in `docs/instagram_story_endpoint_research.md`:
- `POST /graphql/query` (`PolarisStoriesV3TrayContainerQuery`, root `xdt_api__v1__feed__reels_tray`)
- `POST /graphql/query` (`PolarisStoriesV3ReelPageGalleryQuery`)
- `POST /graphql/query` (`PolarisStoriesV3ReelPageGalleryPaginationQuery`, root `xdt_api__v1__feed__reels_media__connection`)
- `POST /graphql/query` (`PolarisStoriesV3SeenMutation`)
- `POST /graphql/query` (`PolarisStoriesV3AdsPoolQuery`)

## Browser-Network Endpoints Observed for Messaging
Documented in `docs/instagram_messaging_api_research.md`:
- Read:
  - `GET /api/v1/direct_v2/inbox/`
  - `GET /api/v1/direct_v2/threads/<thread_id>/`
- Send:
  - `POST /api/v1/direct_v2/create_group_thread/`
  - `POST /api/v1/direct_v2/threads/broadcast/text/`
  - `POST /api/v1/direct_v2/threads/broadcast/reel_share/` (story reply)

## Remaining HTML/UI Dependencies (Not Fully Replaceable Yet)
These still require browser interaction due to viewer/composer mechanics or unstable/publicly undocumented contracts:
- Story viewer lifecycle controls:
  - `open_first_story_from_home_carousel!`
  - `click_next_story_in_carousel!`
  - `current_story_context`
- UI-only fallbacks for:
  - DM send when API send fails
  - post comment when API comment endpoint is rejected
  - follow graph extraction when friendships API is unavailable
- Ad and reaction UX checks in story viewer (partly UI heuristics)

## Recommended Next Steps
1. Add a dedicated worker to periodically refresh `dm_interaction_state` and `story_interaction_state` from API for profiles in `unavailable` state whose retry window has elapsed.
2. Cache thread IDs per profile to reduce repeated `create_group_thread` calls.
3. Expand endpoint telemetry table (HTTP status, error type, reason_code) for API failures to tune retry windows by error class.
