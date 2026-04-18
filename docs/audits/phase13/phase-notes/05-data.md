# Phase 5 — Data / storage validation log

> Rails-console spot checks performed after each Phase 3 / Phase 4 flow.
> Goal: confirm that user actions and background jobs persist what the
> UI claims, and surface missing indexes, redundant storage, or drift
> that hurts scalability.

## Spot-check checklist

- [ ] `InstagramAccount` counters after `sync_next_profiles`,
      `sync_profile_stories`, `run_continuous_processing`
      (`continuous_processing_next_feed_sync_at`, `last_sync_at`, etc.)
- [ ] `BackgroundJobFailure` rows after deliberately-failed trigger
      (fields: `fingerprint`, `retryable`, `failure_kind`, job args
      roundtrip)
- [ ] `AppIssue` dedup (same fingerprint collapses)
- [ ] `ActiveStorage::Attachment` rows + blob bytes after
      `story_media_archive` download + `download_avatar`
- [ ] `InstagramAccountAuditLog` write-through from account page events
- [ ] `Ai::CallLog` / equivalent persistence behind NVIDIA calls

## Schema / index review (pass-through, not table-scanning)

- [ ] `BackgroundJobFailure(fingerprint)` — indexed?
- [ ] `AppIssue(fingerprint)` — indexed and unique?
- [ ] `InstagramProfile(username, instagram_account_id)` — composite?
- [ ] `InstagramPost(posted_at)` — for feed-page sort?
- [ ] Encrypted-at-rest coverage for any column holding cookies or
      Instagram tokens

## Redundancy / retention

- [ ] Detached Active Storage blobs older than N days?
- [ ] Duplicate attachments per profile (`story_media_archive` + per-story)?
- [ ] Stale `BackgroundJobFailure` + `AppIssue` from the
      `CheckLocalAiHealthJob` / `local_ai_stack` era?

## Notes

*(populated during walk)*
