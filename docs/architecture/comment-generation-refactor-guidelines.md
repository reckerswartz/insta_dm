# Comment Generation Refactor Guidelines

Last updated: 2026-02-20

## New Structure

### Event Story Comment Flow

- `InstagramProfileEvent::CommentGenerationCoordinator`
  - Keeps model-facing APIs (`generate_llm_comment!`, status transitions, validations).
  - Delegates orchestration to a dedicated pipeline service.
- `LlmComment::EventGenerationPipeline`
  - Owns end-to-end generation orchestration for a story archive event.
  - Responsibilities:
    - Build and validate context.
    - Enforce local intelligence and verified-policy gates.
    - Call generator and relevance ranker.
    - Persist final event comment and metadata.
    - Broadcast lifecycle progress updates.

### Post Comment Flow

- `Ai::PostCommentGenerationService`
  - Orchestrates use-case level workflow only.
  - No longer owns signal parsing or policy persistence details.
- `Ai::PostCommentGeneration::SignalContext`
  - Encapsulates extraction/normalization of OCR, transcript, face count, topics, and CV/OCR evidence payload.
  - Encapsulates image description and suggestion normalization logic.
- `Ai::PostCommentGeneration::PolicyPersistence`
  - Encapsulates policy-state persistence for both success and blocked outcomes.
  - Keeps policy metadata contract in one place.

## Interaction Model

1. Caller invokes model/service entrypoint (`generate_llm_comment!` or `run!`).
2. Orchestrator builds normalized context through focused collaborators.
3. Policy checks run before model inference where possible.
4. Generator invocation happens only after policy allows.
5. Persistence collaborator writes final analysis/policy metadata.
6. Broadcast/logging side effects are emitted after durable state update.

## Feature Extension Guidelines

1. Add new evidence signals in `SignalContext`; do not spread extraction logic into orchestration services.
2. Add new policy states/reason codes in `PolicyPersistence` to keep metadata shape stable.
3. Add new model/provider routing in orchestration services only; keep persistence and parsing untouched.
4. Keep ActiveRecord model concerns thin: API boundary + domain validation, not orchestration.
5. Preserve return contracts of public entrypoints (`run!`, `generate_llm_comment!`) to avoid job/controller regressions.

## Scalability And Anti-Drift Practices

1. Enforce single responsibility per class:
   - Orchestration, signal extraction, policy persistence, provider invocation separated.
2. Prefer dependency injection (generator/preparation services) for testability and swapability.
3. Keep policy metadata schema centralized and versionable; avoid ad-hoc keys in multiple files.
4. Require targeted specs for:
   - blocked vs enabled policy transitions,
   - successful generation persistence,
   - fallback/error paths.
5. Track class growth with soft limits:
   - trigger extraction once a class exceeds ~250 LOC or mixes 3+ responsibilities.
