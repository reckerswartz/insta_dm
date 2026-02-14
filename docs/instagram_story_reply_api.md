# Instagram Story Reply API Pattern

Last updated: 2026-02-14

## Objective
Send story replies/comments via API calls instead of UI typing/clicking.

## Observed Request Sequence

1. Create/get DM thread for the story owner
- Endpoint: `POST /api/v1/direct_v2/create_group_thread/`
- Form field:
  - `recipient_users`: JSON array string, e.g. `["58837121139"]`
- Response: thread id in one of:
  - `thread_id`
  - `thread.thread_id`
  - `thread.id`

2. Send story reply message
- Endpoint: `POST /api/v1/direct_v2/threads/broadcast/reel_share/`
- Form fields:
  - `action=send_item`
  - `client_context=<unique numeric string>`
  - `media_id=<story_id>_<story_owner_user_id>`
  - `reel_id=<story_owner_user_id>`
  - `text=<reply text>`
  - `thread_id=<thread id from step 1>`

## Identifier Mapping
- `story_id`: from story context (`/stories/<username>/<story_id>/`) or `feed/reels_media` item `pk`.
- `story_owner_user_id`: from `web_profile_info` (`data.user.id`).
- `media_id`: always composed as `<story_id>_<story_owner_user_id>`.
- `thread_id`: returned by `create_group_thread`.

## Success/Failure Examples
- Success:
  - HTTP `200`, JSON `status: "ok"`, payload contains `item_id` and `thread_id`.
- Failure:
  - HTTP `403`, JSON `status: "fail"`, payload includes `error_code` and message (example `1545003` when recipient/thread action is blocked).

## Current Implementation
- API-first reply method:
  - `comment_on_story_via_api!` in `app/services/instagram/client.rb`
- Used in:
  - `sync_home_story_carousel!` (fallback to UI if API fails)
  - `auto_engage_first_story!` (fallback to UI if API fails)
