# Admin AI Provider Settings — `/admin/ai_provider_settings`

## Snapshot

- **URL:** `/admin/ai_provider_settings`
- **View:** `app/views/admin/ai_provider_settings/index.html.erb`
- **Screenshot (before):** `../screenshots/before/14-admin-ai-provider.png`
- **DB state:** 5 enabled NVIDIA rows (embedding, text_fast,
  text_quality, vision_fallback, vision_primary); a second table
  "Local provider (legacy)" is empty.
- **Captured at:** 2026-04-18 10:22 UTC

## Clarity of content

- Page header explains the contract: "NVIDIA Build uses one row per
  semantic role … callers pick models via `Ai::NvidiaModelRouter`
  without redeploying."
- Shared-credential hint is clear: *"a shared API key is present in
  Rails credentials and will be used for any row whose own `api_key`
  is blank"*.
- API key cells show `(uses credentials)` placeholder, not the real
  secret — good.

## UI / UX consistency

- Each role row has Save + Test key buttons. Consistent.

## Missing or redundant elements

- **"Local provider (legacy)"** section is kept with a message "scheduled
  for soft-deprecation in Phase 4 of the NVIDIA migration." But Phase 9
  removed LocalProvider (see commit `3fbafbf phase9: remove LocalProvider
  and make the provider registry NVIDIA-only`). The section is therefore
  dead weight and the copy is wrong.

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| `Enabled` checkbox | toggle | PATCH settings row, disables routing | Phase 2 deferred (would turn off LLM round-trip tests) |
| `Model` textbox | fill | PATCH settings row | Phase 2 deferred |
| `Test key` button | click | GET `/v1/models` via NvidiaClient | Phase 4 |
| `Save` button | click | PATCH settings row | Phase 2 deferred |

Destructive controls inventoried (not fired):

| Control | Why deferred |
|---|---|
| Toggling `Enabled` off on `text_fast` or `text_quality` | turns off LLM comment generation globally |

## Background jobs triggered

- None — this page is config only.

## LLM calls observed

- `Test key` exercised in Phase 4.

## Data / storage validation

- `AiProviderSetting` table has 5 rows. `api_key` should be encrypted
  at rest; spot-check that column declaration in Phase 5.

## Findings

### Critical

- *(none)*

### Improvement

- **`F-admin-ai-provider-I1`** — Remove the "Local provider (legacy)"
  section and the Phase-4 deprecation copy. Both reference a provider
  that was deleted in Phase 9. Dead code in the view and potentially in
  the controller / query.
  Source: `app/views/admin/ai_provider_settings/index.html.erb`,
  `app/services/ai/provider_registry.rb`.
- **`F-admin-ai-provider-I2`** — `Test key` button has no loading
  indicator; the button should disable + show a spinner while the
  HTTP round-trip is in flight.

### Optional

- **`F-admin-ai-provider-O1`** — Consider grouping roles by purpose
  (text / vision / embedding) with sub-headings for readability.

## Proposed fixes

### Will land in this branch

- Delete the "Local provider (legacy)" view block and verify the
  underlying query/service no longer enumerates legacy providers.
  Update any specs that asserted its presence.
- Stimulus controller to disable the `Test key` button + show an inline
  spinner while the fetch is in flight.

### Deferred

- Group-by-purpose reorder (minor visual polish).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
