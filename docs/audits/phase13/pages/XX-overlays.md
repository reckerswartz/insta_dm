# Cross-cutting overlays — sidebar / topbar / notifications / modals

> Shared across every page in `app/views/layouts/application.html.erb`
> and `app/views/shared/*`. Findings consolidated here instead of
> per-page to avoid duplication.

## Snapshot

- Shared UI: sidebar brand + nav (9 sections + "Operations"), topbar
  with Menu toggle, page title, quick nav, current-account pill,
  flash stack, queue-health banner, notification center, modals
  partial.
- Captured in every page-level screenshot.

## Clarity of content

- Sidebar brand "InstaManager / Operations Console" is distinct from
  page title "Dashboard" / "Instagram Profiles" etc.
- "Session Active" pill at the bottom of the sidebar is green-dotted
  but references nothing measurable — it's always "Session Active"
  regardless of the actual Instagram-session state of the selected
  account.

## UI / UX consistency

- Sidebar, topbar, flash stack, and notification overlay render
  identically on all pages.
- Topbar Quick Nav duplicates sidebar targets — mild redundancy but
  the Quick Nav acts as a persistent breadcrumb on narrow viewports.
- `flash[:notice]` and `flash[:alert]` both auto-close after 5 s via
  inline JS (`setTimeout(…, 5000)`) — this is only a visual close,
  Bootstrap's Alert instance is used; check that the timing doesn't
  dismiss critical errors (e.g. auth failures) before the operator
  reads them.

## Missing or redundant elements

- "Session Active" pill has no real signal; replace with current
  account's Cookie Auth state, or remove.
- Queue health banner has a dismiss button — dismissing for real
  operator errors is fine, but there's no follow-up escalation.
- `/favicon.ico` is requested by the browser but Rails has **no route**
  for it, logging `ActionController::RoutingError (No route matches
  [GET] "/favicon.ico")` on nearly every page navigation
  (see `log/development.log` — dozens of occurrences). A `favicon.ico`
  file in `public/` or a `favicon_link_tag` override would stop the
  noise.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| Sidebar toggle (mobile) | click | `body.classList.toggle("sidebar-open")` | Phase 2 ✅ |
| Sidebar backdrop | click | close sidebar | Phase 2 ✅ |
| `Escape` key | press | close sidebar | Phase 2 ✅ |
| Window resize | event | auto-close sidebar on wide viewport | Phase 2 ✅ |
| Topbar account pill → account show | click | `/instagram_accounts/:id` | ✅ |
| Flash `Close` button | click | dismiss alert | ✅ |
| `turbo_stream_from current_account` | subscribe | live DOM updates | ✅ (no events during walk) |

## Background jobs triggered

- None.

## LLM calls observed

- None.

## Data / storage validation

- `current_account` is session-backed via `session[:instagram_account_id]`
  with fallback to `InstagramAccount.order(:id).first`. Bootstraps a
  new account from `Rails.application.config.x.instagram.username` if
  the DB is empty. Good defensive fallback for first-run.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-overlays-I1`** — "Session Active" pill is a static string. Wire
  it to `current_account.cookie_auth_valid?` so operators see an actual
  signal (Authenticated / Cookie expired / No account).
- **`F-overlays-I2`** — `/favicon.ico` has no route and floods
  `log/development.log` with `ActionController::RoutingError` noise
  on every navigation. Add `public/favicon.ico` (or a `favicon_link_tag`
  override that points to `/icon.svg`).
- **`F-overlays-I3`** — Flash alerts auto-close after 5 s even for
  `alert`/`danger` variants. For error-variant flashes, either disable
  auto-close or extend to 15 s.

### Optional

- **`F-overlays-O1`** — Topbar Quick Nav duplicates four sidebar
  targets; small redundancy. Keep for mobile, hide on desktop.

## Proposed fixes

### Will land in this branch

- Commit 1: `public/favicon.ico` (copy or redirect to `icon.svg`).
  Regression spec asserting `GET /favicon.ico` returns 200/301.
- Commit 2: Hook "Session Active" pill to
  `current_account.cookie_auth_valid?` + label with state name.
- Commit 3: Differentiate flash auto-close timing — 5 s for
  `notice`/`success`, 15 s for `alert`/`danger`.

### Deferred

- Topbar Quick Nav mobile-only toggle (cosmetic).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshots captured (verify no favicon 404 in log)
