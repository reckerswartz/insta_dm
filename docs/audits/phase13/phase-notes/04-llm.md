# Phase 4 — LLM integration validation log

> Features exercised, model / role routed through, prompt + output
> snapshots, latency, retry behaviour.

## Features exercised

- [ ] `POST /instagram_accounts/:id/generate_llm_comment`
- [ ] `POST /ai_dashboard/test_service`
- [ ] `POST /ai_dashboard/test_all_services`
- [ ] `POST /admin/ai_provider_settings/:id/test_key`
- [ ] Any profile-scoped LLM comment flow reachable via the UI

## Call log

| Timestamp | Feature | Role | Model | Latency | Status | Prompt sha / summary | Output summary | Quality notes |
|---|---|---|---|---|---|---|---|---|
| *(empty)* | | | | | | | | |

## Quality rubric (objective gates)

- [ ] Output is non-empty
- [ ] Output length within feature-specific bounds
- [ ] No prompt / system-instruction leakage in output
- [ ] Refusal / guardrail responses surface a user-visible alert, not a
      silent empty string
- [ ] Role resolved through `ai_provider_settings` matches the feature
      contract (e.g. `text_fast` for comments)

## Narrative quality notes

*(populated during walk — tone, relevance, repetition, variance)*

## Proposed prompt / routing changes

*(fed into Phase 7 commits)*
