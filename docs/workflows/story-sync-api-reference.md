# Story Sync API Reference

Last updated: 2026-02-21

## Purpose

This document captures the current story sync data sources and confirms where API endpoints are used instead of DOM scraping. It is the migration reference for keeping story syncing resilient when Instagram page markup changes.

## Story Sync Workflows in Scope

### A) Profile story sync job

- Job: `SyncInstagramProfileStoriesJob`
- Entry API call chain:
  1. `GET /api/v1/users/web_profile_info/?username=<username>`
  2. `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`
- Implementation path:
  - `Instagram::Client#fetch_profile_story_dataset!`
  - `Instagram::Client::ProfileStoryDatasetService`
  - `Instagram::Client::StoryApiSupport`

### B) Home carousel story sync

- Entry point: `Instagram::Client#sync_home_story_carousel!`
- Viewer navigation is UI-driven, but story data extraction is API-first:
  1. `GET /api/v1/users/web_profile_info/?username=<username>`
  2. `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`
- DOM/performance extraction is fallback-only when API media cannot be resolved.

## Scraping Inventory and API Replacements

| Area | Previous DOM/HTML dependence | Current API replacement | Status |
|---|---|---|---|
| Profile story dataset retrieval | Could depend on rendered story page state in fragile paths | `users/web_profile_info` + `feed/reels_media` | API-based |
| Home story media URL resolution | Visible `<img>/<video>` probing and perf logs | `resolve_story_item_via_api` using `web_profile_info` + `reels_media` | API-first, DOM fallback only |
| Story user prefetch for opening routes | Home feed element discovery | `GET /api/v1/feed/reels_tray/` | API-based |
| Story reply eligibility | UI textbox/marker detection | API story item field `can_reply` | API-first, UI fallback only if unknown |
| External attribution / reshare skip | UI marker detection | API-derived attribution signals from story item payload | API-based |
| Story reply submission | UI comment box interaction | `POST /api/v1/direct_v2/create_group_thread/` then `POST /api/v1/direct_v2/threads/broadcast/reel_share/` | API-first, UI fallback only on API failure |

## Endpoint Catalog

### `GET /api/v1/users/web_profile_info/?username=<username>`

Used for:
- resolving canonical `user.id` required by reels endpoints
- profile metadata used by story dataset sync

Expected response fields used:
- `data.user.id`
- `data.user.username`
- profile metadata fields (`full_name`, `profile_pic_url_hd`, `biography`, `follower_count`, etc.)

### `GET /api/v1/feed/reels_media/?reel_ids=<user_id>`

Used for:
- story item retrieval for a reel owner
- media URL and metadata extraction

Expected response shapes handled:
- `reels[<user_id>]`
- `reels_media[]`

Story fields extracted per item:
- identifiers: `story_id`, owner ids/usernames
- media: `media_url`, `image_url`, `video_url`, `media_type`, width/height, variant metadata
- timeline: `taken_at`, `expiring_at`
- interaction: `can_reply`, `can_reshare`
- attribution flags: external profile indicators and targets

### `GET /api/v1/feed/reels_tray/`

Used for:
- collecting available story tray users for sync/prefetch

Expected fields used:
- `tray[]` or `tray.items[]`
- per-user `username`, `full_name`, `profile_pic_url`

### `GET /api/v1/direct_v2/inbox/?...`

Used for:
- collecting conversation users in sync workflows

Pagination:
- uses `oldest_cursor`
- page size capped per request, with bounded loop safety

### `POST /api/v1/direct_v2/create_group_thread/`

Used for:
- creating/reusing a thread for story reply transport

Required form field:
- `recipient_users` JSON array string (user id list)

### `POST /api/v1/direct_v2/threads/broadcast/reel_share/`

Used for:
- sending story reply/comment payload through direct thread transport

Required form fields:
- `action=send_item`
- `client_context`
- `media_id=<story_id>_<owner_user_id>`
- `reel_id=<owner_user_id>`
- `thread_id`
- `text`

## Required Headers and Session Data

All Instagram API requests are sent with authenticated web-session context:

- `User-Agent`
- `Accept: application/json, text/plain, */*`
- `X-Requested-With: XMLHttpRequest`
- `X-IG-App-ID`
- `Referer`
- `X-CSRFToken` (from `csrftoken` cookie when available)
- `Cookie` (serialized account cookie jar)

POST requests also include:
- `Content-Type: application/x-www-form-urlencoded; charset=UTF-8`

## Authentication and Browser-Context Fallback

Primary path:
- direct HTTP request with account cookies + CSRF + IG headers

Fallback path when direct API access fails:
- browser-context `fetch()` with `credentials: "include"` via Selenium driver
- used by `ig_api_get_json` when driver context is available

This is now threaded through story item/reel resolution paths to reduce false failures that previously dropped to DOM extraction.

## Pagination and Rate Limit Handling

- `ig_api_get_json` retry strategy:
  - bounded retry attempts (`retries + 1`, clamped)
  - backoff sleep between retries
  - retryable statuses: `429`, `5xx`, and transport-level failures
- rate-limit telemetry:
  - structured log event: `instagram.api_get_json.failure`
  - stores recent endpoint failure state per username for sync diagnostics
- endpoint-specific pagination:
  - `reels_media`: no cursor-based pagination in current use (single reel owner request)
  - `reels_tray`: single fetch in current use
  - `direct_v2/inbox`: cursor loop with bounded safety and per-page limits

## Error Cases and Retry Strategy

### API request failures

Behavior:
- retry when retryable
- browser-context API fallback when driver is present
- structured warning with endpoint/status/reason/snippet

### Story media unresolved

Home carousel resolution order:
1. API reels media
2. DOM visible media fallback
3. performance-log media fallback

If all fail:
- `story_sync_failed` with reason `api_story_media_unavailable`
- includes attempt-source metadata and latest API failure state

### Reply/API transport failures

Behavior:
- story reply attempts API first
- UI reply fallback only if API post fails
- skip events capture reason/status for operational triage

## DOM Change / Partial-Load Failure Signatures

Observed failure reasons in story sync telemetry:
- `story_context_missing`
- `story_context_missing_after_view_gate`
- `story_view_gate_not_cleared`
- `story_page_unavailable`
- `story_id_unresolved`

How API-first retrieval reduces impact:
- story ids/media are resolved from `reels_media` payload when URL context is unstable
- replyability and attribution are evaluated from API fields before UI markers
- browser-context API fallback (`credentials: include`) is attempted before DOM media probing

## Remaining DOM Reliance (Non-Primary Data Source)

DOM is still used for:
- opening/navigating the story viewer UI
- view-gate interaction and viewer readiness checks
- fallback media extraction only after API resolution fails

DOM is not the primary source for canonical story identifiers/media metadata in the sync flow.

## Migration Validation Checklist

- story dataset sync obtains story items from `web_profile_info + reels_media`
- canonical fields available per story item:
  - media URL(s)
  - timestamps (`taken_at`, `expiring_at`)
  - canonical identifier (`story_id`)
- API call headers/session fields are consistently present
- retries and structured logging are active for endpoint failures
- fallback behavior activates only when API resolution/posting fails
