# Phase 1 — Full UI exploration log

> Running log of the MCP-driven page walk. One section per page slug. Each
> section records the minimum viable artefact: navigate succeeded, screenshot
> path, viewport, scroll coverage, and a short free-form description. Detailed
> findings live in `../pages/<slug>.md`.

## Environment

- Rails: `bin/dev` at `http://localhost:3000`
- MCP sidecar: `@playwright/mcp` launched in isolated mode (ephemeral
  user-data dir `tmp/audit_profile/`, no Instagram session involved)
- DB state at start: _recorded below after first navigate._

## Page walk

### 01 · dashboard — `/`

- Status: pending

### 02 · account-show — `/instagram_accounts/:id`

- Status: pending

### 03 · workspace-actions — `/workspace/actions`

- Status: pending

### 04 · profiles-index — `/instagram_profiles`

- Status: pending

### 05 · profile-show — `/instagram_profiles/:id`

- Status: pending

### 06 · story-people-show — `/instagram_profiles/:id/people/:person_id`

- Status: pending

### 07 · posts-index — `/instagram_posts`

- Status: pending

### 08 · post-show — `/instagram_posts/:id`

- Status: pending

### 09 · ai-dashboard — `/ai_dashboard`

- Status: pending

### 10 · admin-background-jobs — `/admin/background_jobs`

- Status: pending

### 11 · admin-failures — `/admin/background_jobs/failures`

- Status: pending

### 12 · admin-issues — `/admin/issues`

- Status: pending

### 13 · admin-storage — `/admin/storage_ingestions`

- Status: pending

### 14 · admin-ai-provider — `/admin/ai_provider_settings`

- Status: pending

### 15 · admin-mission-control — `/admin/jobs`

- Status: pending

### XX · overlays — sidebar / topbar / modals / notifications / queue-health banner

- Status: pending
