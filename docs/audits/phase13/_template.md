# <Page name> — `<route>`

> Template for Phase 13 per-page audit files. Copy to `pages/<slug>.md`, fill in,
> keep section headings verbatim so `FINDINGS.md` aggregation stays mechanical.

## Snapshot

- **URL:** `<path>` (controller `<controller#action>`, view `<path/to/view>`)
- **Screenshot (before):** `../screenshots/before/<slug>.png`
- **Screenshot (after):** `../screenshots/after/<slug>.png` *(filled during Phase 8)*
- **Account context:** `<account username>` *(dev DB)*
- **DB state summary:** `<counts of rows / attachments relevant to this page>`
- **Viewport / scroll coverage:** `<above-the-fold | scrolled to bottom | …>`
- **Captured at:** `<ISO timestamp>`

## Clarity of content

- `<bullet — is the purpose of the page obvious from copy alone?>`
- `<bullet — are numbers and state indicators self-explanatory?>`

## UI / UX consistency

- `<bullet — fonts, buttons, spacing match sibling pages?>`
- `<bullet — any Bootstrap / custom-component collision?>`

## Missing or redundant elements

- `<bullet — duplicated links, dead partials, missing empty-state copy>`

## Interactive elements tested

| Selector / control | Action | Expected | Actual | Status |
|---|---|---|---|---|
| `<button>` | click | `<behaviour>` | `<behaviour>` | ✅ / ⚠️ / ❌ |

Destructive controls that were **inventoried but not fired** (await explicit operator confirmation):

| Selector / control | Why deferred |
|---|---|
| `<button>` | `<reason, e.g. wipes queue>` |

## Background jobs triggered

| Job class | Queue | Trigger | Outcome | Log excerpt | Notes |
|---|---|---|---|---|---|
| `<ExampleJob>` | `sync` | button X | ok | `"[ts] …"` | latency … |

## LLM calls observed

| Feature | Role / model | Prompt summary | Output summary | Latency | Quality notes |
|---|---|---|---|---|---|
| `<feature>` | `text_fast → meta/llama3-…` | `<n chars>` | `<n chars>` | `<ms>` | `<bullet>` |

## Data / storage validation

- `<bullet — Active Record counts after flow>`
- `<bullet — Active Storage attachments / retention>`
- `<bullet — missing indexes, encryption, redundancy>`

## Findings

### Critical

- *(none)* OR `F-<slug>-C1: <one-line summary>` — impact + source file.

### Improvement

- `F-<slug>-I1: <one-line summary>` — impact + source file.

### Optional

- `F-<slug>-O1: <one-line summary>` — impact + source file.

## Proposed fixes

### Will land in this branch (Phase 7)

- `<bullet linked to finding id>` — implementation sketch + files touched.

### Deferred to follow-up phase

- `<bullet>` — reason deferral is safer than landing now.

## Phase 8 status

- [ ] Findings complete
- [ ] Fixes landed (commits: `<sha>…`)
- [ ] Re-walk screenshot captured under `screenshots/after/`
