# Instagram Messaging API Research

Last updated: 2026-02-14

## Objective
Document DM-related network endpoints so messaging and inbox extraction can rely on API calls instead of HTML/UI parsing where possible.

## Confirmed Read Endpoints

1. Inbox thread list
- Endpoint: `GET /api/v1/direct_v2/inbox/?limit=<n>&visual_message_return_type=unseen`
- Purpose: list recent threads and participants (`inbox.threads[].thread_users[]`)
- Current use: `fetch_conversation_users_via_api`

2. Thread details and messages
- Endpoint: `GET /api/v1/direct_v2/threads/<thread_id>/?limit=<n>`
- Also works without `limit` (`GET /api/v1/direct_v2/threads/<thread_id>/`)
- Purpose: returns `thread.items[]` (message records), user list, and paging flags
- Verified via runner in this workspace (returned `status: "ok"` with `thread.items`)

3. Direct-new recipient search
- Endpoint: `GET /api/v1/direct_v2/ranked_recipients/`
- Endpoint: `GET /api/v1/direct_v2/search_secondary/`
- Purpose: recipient suggestions and search while composing DM
- Observed in performance logs from `dm_open_direct_new`

## Confirmed Send Endpoints

1. Create/get thread from user id
- Endpoint: `POST /api/v1/direct_v2/create_group_thread/`
- Body form: `recipient_users=["<user_id>"]`
- Purpose: resolve/create `thread_id`
- Observed repeatedly in story-reply network captures

2. Story reply as DM message
- Endpoint: `POST /api/v1/direct_v2/threads/broadcast/reel_share/`
- Body form keys:
  - `action=send_item`
  - `client_context=<unique id>`
  - `media_id=<story_id>_<story_owner_user_id>`
  - `reel_id=<story_owner_user_id>`
  - `text=<reply text>`
  - `thread_id=<thread_id>`
- Purpose: send a story reply/comment via DM transport
- Observed with successful and failed responses in captured logs

## Text DM Send Endpoint (API-First Candidate)

- Endpoint: `POST /api/v1/direct_v2/threads/broadcast/text/`
- Expected form keys:
  - `action=send_item`
  - `client_context=<unique id>`
  - `thread_id=<thread_id>`
  - `text=<message body>`
- Implemented in client as API-first path with UI fallback:
  - `send_direct_message_via_api!`
  - `send_message_to_user!` now tries API first, then existing UI flow on failure

## Web UI Transport Notes

- DM web UI also emits high-volume internal requests like `POST /ajax/bz` with LS/Falco payloads.
- Those calls are noisy and less stable for direct implementation than `direct_v2` endpoints.
- Recommendation: prefer `direct_v2` JSON endpoints for extraction and send logic, keep UI fallback for resilience.

## Code References

- `app/services/instagram/client.rb:2483` (`fetch_conversation_users_via_api`)
- `app/services/instagram/client.rb:1112` (`send_messages!` API-first batch send + UI fallback)
- `app/services/instagram/client.rb:1165` (`send_message_to_user!` API-first + UI fallback)
- `app/services/instagram/client.rb:1203` (`send_direct_message_via_api!`)
- `app/services/instagram/client.rb:5415` (`ig_api_post_form_json`)
- `docs/instagram_story_reply_api.md` (story reply send payload details)

## Next Development Steps

1. Add `fetch_thread_messages_via_api(thread_id:, limit:)` wrapper for `direct_v2/threads/<id>/` and migrate any DM message reads to it.
2. Store `thread_id` per profile after first resolve to avoid repeated `create_group_thread` calls.
3. Keep UI send fallback until API send success rate is stable across sessions/accounts.
