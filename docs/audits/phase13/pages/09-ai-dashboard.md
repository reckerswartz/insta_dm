# AI Services — `/ai_dashboard` → `ai_dashboard#index`

## Snapshot

- **URL:** `/ai_dashboard`
- **View:** `app/views/ai_dashboard/index.html.erb`
- **Screenshot (before):** `../screenshots/before/09-ai-dashboard.png`
- **DB state:** 5 `AiProviderSetting` rows (all 5 roles enabled).
- **Live probe:** *"NVIDIA Build online — less than a minute ago (live
  check)"*. 132+ available models listed. Services: Rails Web / Sidekiq
  Worker / Redis all `Running`.
- **Captured at:** 2026-04-18 10:21 UTC

## Clarity of content

- Clear NVIDIA status pill + freshness timestamp.
- `Runtime Architecture > Policy` correctly reports
  `Execution mode: nvidia_build`.
- `Configured Models` table surfaces each role → model mapping with the
  canonical `text_fast`, `text_quality`, `vision_primary`,
  `vision_fallback`, `embedding` set.
- `Concurrent AI Lanes` table is rich: lane name, queue, concurrency,
  pending, 24 h API calls, 24 h failures, 24 h tokens, new-item ETA,
  drain ETA, ETA confidence, registered job classes, data impact.

## UI / UX consistency

- Table styles match admin pages.
- "Lightweight Controls" block lists `post_video_lightweight=true`,
  `skip_dynamic_with_audio=true`, `frame_sample_limit=3`,
  `dynamic_keyframes=2` — these are feature flags, not stats. Consider
  moving them into an `<details>` to reduce noise.

## Missing or redundant elements

- `ETA confidence: low n=14 / low n=0 / low n=9 / low n=0 / …`:
  every lane has `low` confidence despite the system having plenty of
  historical samples. Either the sample window is too narrow or the
  confidence formula is broken.
- No `Cleanup candidates` block despite the subtitle copy promising
  "NVIDIA Build status, concurrent lanes, **and cleanup candidates**".

## Interactive elements tested

| Control | Action | Expected | Phase |
|---|---|---|---|
| `Run test` (NVIDIA row) | click | `POST /ai_dashboard/test_service` → NVIDIA round-trip | Phase 4 |
| `Run all tests` | click | `POST /ai_dashboard/test_all_services` | Phase 4 |
| `Refresh status` | click | re-render status block | Phase 2 ✅ |
| `Dashboard` / `Background Jobs` in-page shortcuts | click | navigate | Phase 2 ✅ |

## Background jobs triggered

- None triggered from this page (it's a live-probe surface).

## LLM calls observed

- `Ai::NvidiaClient#list_models!` is called on page load for the live
  status check. Response included > 130 models, which is rendered into
  the "Available models" paragraph. See Phase 4 for prompt/round-trip
  testing.

## Data / storage validation

- `AiProviderSetting.count = 5` confirmed (all roles enabled). Each has
  `base_url=https://integrate.api.nvidia.com/v1`, priority=2, api_key is
  masked (`uses credentials`).

## Findings

### Critical

- *(none)*

### Improvement

- **`F-ai-dashboard-I1`** — `Cleanup candidates` block advertised by the
  subtitle does not exist on the page. Either add the section (list of
  stale/unused models or roles) or remove the promise from the copy.
- **`F-ai-dashboard-I2`** — Every lane's ETA confidence shows `low`.
  Audit the confidence heuristic — with lanes that have `n=14` or
  `n=10` samples this should not all be `low`.
  Source: `app/services/ai_dashboard/lane_summary.rb` (or equivalent).
- **`F-ai-dashboard-I3`** — `Lightweight Controls` section repeats four
  feature-flag flags in raw `<code>` without context on where to change
  them. Link each to the config key it maps to or collapse the whole
  thing into a collapsible `<details>`.

### Optional

- **`F-ai-dashboard-O1`** — `Available models` list gets truncated with
  a trailing `...`. Provide a full list on hover/click.

## Proposed fixes

### Will land in this branch

- Either add the `Cleanup candidates` block or rewrite the subtitle.
  Concretely: fetch `Ai::Cleanup::Candidates.call(account)` and render
  the result as a third card.
- Fix the ETA confidence heuristic thresholds (`high` ≥ N ≥ 30,
  `medium` ≥ 10, else `low`).
- Move `Lightweight Controls` into a collapsible block.

### Deferred

- Hover/click expansion of the available-models list (UI polish,
  low priority).

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed
- [ ] Re-walk screenshot captured
