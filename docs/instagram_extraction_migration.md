# Instagram Extraction Migration (API-First)

Last updated: 2026-02-14

## Objective
Reduce brittle HTML parsing for Instagram data extraction by preferring authenticated API/network endpoints.

## Updated Paths

1. Conversation users (DM inbox)
- Method: `collect_conversation_users`
- New primary source: `/api/v1/direct_v2/inbox/`
- Fallback: existing inbox HTML payload parsing (`verifyContactRowExists` segments)

2. Story users (home tray)
- Method: `collect_story_users`
- New primary source: `/api/v1/feed/reels_tray/`
- Fallback: existing story link/HTML parsing

3. Follow graph (followers/following)
- Method: `collect_follow_list`
- New primary source:
  - `/api/v1/friendships/<user_id>/followers/`
  - `/api/v1/friendships/<user_id>/following/`
- Fallback: existing modal DOM scrolling extraction

4. Home feed post discovery
- Method: `extract_feed_items_from_dom`
- New primary source: `/api/v1/feed/timeline/`
- Fallback: existing DOM link/media extraction

5. Profile details
- Method: `fetch_profile_details_from_driver`
- New primary source: `web_profile_info` + API latest-post extraction
- Fallback: existing DOM/HTML extraction logic

6. Story media download URL resolution
- Method: `resolve_story_media_for_current_context` (already added earlier)
- Primary source:
  - `/api/v1/users/web_profile_info/?username=...`
  - `/api/v1/feed/reels_media/?reel_ids=...`
- Fallback: `extract_story_media_from_dom`

7. Auto-engage initial story selection
- Method: `auto_engage_first_story!`
- New primary source: tray usernames from `/api/v1/feed/reels_tray/`
- Fallback: DOM story anchors

8. DM send (single-user send path)
- Method: `send_message_to_user!`
- New primary source: `/api/v1/direct_v2/threads/broadcast/text/`
- Supporting endpoints:
  - `/api/v1/users/web_profile_info/?username=...` (resolve user id)
  - `/api/v1/direct_v2/create_group_thread/` (resolve/create thread id)
- Fallback: existing DM UI composer flow

## New Shared Helper
- `ig_api_get_json(path:, referer:)`
- Centralized authenticated GET with session cookies and IG headers.

## Remaining DOM-Required Areas
- UI actions requiring visible controls: opening story viewer, clicking next, posting replies/comments, DM composer interaction.
- Messageability check (`fetch_eligibility`) still relies on CTA visibility in profile UI.
- These are interaction workflows, not data extraction endpoints.
