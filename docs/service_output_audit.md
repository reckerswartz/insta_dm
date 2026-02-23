# Service Output Audit

This audit captures what each service/job output produces, what is persisted to database-backed objects, and what appears unused at the step boundary.

## What is tracked

- Executed service name (`service_name`)
- Execution source class (`execution_source`)
- Pipeline/job context IDs:
  - `instagram_account_id`
  - `instagram_profile_id`
  - `instagram_profile_post_id`
  - `instagram_profile_event_id`
- Output structure:
  - `produced_paths`
  - `produced_leaf_keys`
  - `referenced_paths`
  - `persisted_paths`
  - `unused_leaf_keys`
- Summary counts:
  - `produced_count`
  - `referenced_count`
  - `persisted_count`
  - `unused_count`
- Run metadata:
  - `run_id`
  - `active_job_id`
  - `queue_name`
  - status + error metadata when failed

## Storage

- Table: `service_output_audits`
- Model: `ServiceOutputAudit`
- Recorder: `Ops::ServiceOutputAuditRecorder`
- Snapshot aggregation: `Ops::ServiceOutputAuditSnapshot`

## Instrumented flows

- Post-analysis step jobs (`PostAnalysisStepJob` base), including:
  - `ProcessPostVisualAnalysisJob` (`Ai::Runner`)
  - `ProcessPostOcrAnalysisJob` (`Ai::PostOcrService`)
  - `ProcessPostVideoAnalysisJob` (`PostVideoContextExtractionService`)
- Post metadata finalization:
  - `ProcessPostMetadataTaggingJob`
- Story comment pipeline:
  - `LlmComment::StoryIntelligencePayloadResolver`
  - `LlmComment::EventGenerationPipeline`

## How to analyze

- Admin dashboard section:
  - `Admin > Background Jobs > Service Output Audit (24h)`
- Programmatic metrics payload:
  - `Ops::Metrics.system[:service_output_audits_24h]`
  - `Ops::Metrics.for_account(account)[:service_output_audits_24h]`

## Notes on interpretation

- `unused_leaf_keys` means keys produced by the service output that were neither:
  - persisted in detected model changes, nor
  - referenced in immediate completion payloads.
- This is a strong signal for possible redundancy, but not absolute proof of dead data.
- Use repeated observations over time before removing fields or disabling processing.
