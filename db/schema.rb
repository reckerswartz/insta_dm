# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_02_18_050100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_ingestions", force: :cascade do |t|
    t.bigint "active_storage_attachment_id", null: false
    t.bigint "active_storage_blob_id", null: false
    t.string "attachment_name", null: false
    t.bigint "blob_byte_size", null: false
    t.string "blob_content_type"
    t.string "blob_filename", null: false
    t.datetime "created_at", null: false
    t.string "created_by_active_job_id"
    t.string "created_by_job_class"
    t.string "created_by_provider_job_id"
    t.bigint "instagram_account_id"
    t.bigint "instagram_profile_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "queue_name"
    t.bigint "record_id"
    t.string "record_type"
    t.datetime "updated_at", null: false
    t.index ["active_storage_attachment_id"], name: "idx_storage_ingestions_attachment_unique", unique: true
    t.index ["created_at"], name: "index_active_storage_ingestions_on_created_at"
    t.index ["created_by_active_job_id"], name: "index_active_storage_ingestions_on_created_by_active_job_id"
    t.index ["created_by_job_class"], name: "index_active_storage_ingestions_on_created_by_job_class"
    t.index ["instagram_account_id"], name: "index_active_storage_ingestions_on_instagram_account_id"
    t.index ["instagram_profile_id"], name: "index_active_storage_ingestions_on_instagram_profile_id"
    t.index ["record_type", "record_id"], name: "idx_storage_ingestions_record"
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_analyses", force: :cascade do |t|
    t.json "analysis"
    t.bigint "analyzable_id", null: false
    t.string "analyzable_type", null: false
    t.boolean "cache_hit", default: false, null: false
    t.bigint "cached_from_ai_analysis_id"
    t.float "confidence_score"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "evidence_count"
    t.datetime "finished_at"
    t.float "input_completeness_score"
    t.integer "instagram_account_id", null: false
    t.string "media_fingerprint"
    t.json "metadata"
    t.string "model"
    t.text "prompt"
    t.string "prompt_version"
    t.string "provider", null: false
    t.string "purpose", null: false
    t.text "response_text"
    t.string "schema_version"
    t.integer "signals_detected_count"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["analyzable_type", "analyzable_id", "created_at"], name: "idx_ai_analyses_on_analyzable_created"
    t.index ["analyzable_type", "analyzable_id"], name: "index_ai_analyses_on_analyzable"
    t.index ["cached_from_ai_analysis_id"], name: "index_ai_analyses_on_cached_from_ai_analysis_id"
    t.index ["confidence_score"], name: "index_ai_analyses_on_confidence_score"
    t.index ["instagram_account_id", "created_at"], name: "index_ai_analyses_on_instagram_account_id_and_created_at"
    t.index ["instagram_account_id"], name: "index_ai_analyses_on_instagram_account_id"
    t.index ["provider", "purpose", "status"], name: "index_ai_analyses_on_provider_and_purpose_and_status"
    t.index ["purpose", "media_fingerprint", "status"], name: "idx_ai_analyses_reuse_lookup"
    t.index ["purpose", "provider", "created_at"], name: "index_ai_analyses_on_purpose_and_provider_and_created_at"
  end

  create_table "ai_api_calls", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "http_status"
    t.integer "input_tokens"
    t.bigint "instagram_account_id"
    t.integer "latency_ms"
    t.json "metadata"
    t.datetime "occurred_at", null: false
    t.string "operation", null: false
    t.integer "output_tokens"
    t.string "provider", null: false
    t.integer "request_units"
    t.string "status", null: false
    t.integer "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["category", "occurred_at"], name: "index_ai_api_calls_on_category_and_occurred_at"
    t.index ["instagram_account_id", "occurred_at"], name: "index_ai_api_calls_on_instagram_account_id_and_occurred_at"
    t.index ["instagram_account_id"], name: "index_ai_api_calls_on_instagram_account_id"
    t.index ["occurred_at"], name: "index_ai_api_calls_on_occurred_at"
    t.index ["operation", "occurred_at"], name: "index_ai_api_calls_on_operation_and_occurred_at"
    t.index ["provider", "occurred_at"], name: "index_ai_api_calls_on_provider_and_occurred_at"
    t.index ["status", "occurred_at"], name: "index_ai_api_calls_on_status_and_occurred_at"
  end

  create_table "ai_provider_settings", force: :cascade do |t|
    t.text "api_key"
    t.json "config"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.integer "priority", default: 100, null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled", "priority"], name: "index_ai_provider_settings_on_enabled_and_priority"
    t.index ["provider"], name: "index_ai_provider_settings_on_provider", unique: true
  end

  create_table "app_issues", force: :cascade do |t|
    t.bigint "background_job_failure_id"
    t.datetime "created_at", null: false
    t.text "details"
    t.string "fingerprint", null: false
    t.datetime "first_seen_at", null: false
    t.bigint "instagram_account_id"
    t.bigint "instagram_profile_id"
    t.string "issue_type", null: false
    t.datetime "last_seen_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "occurrences", default: 1, null: false
    t.text "resolution_notes"
    t.datetime "resolved_at"
    t.string "severity", default: "error", null: false
    t.string "source", null: false
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["background_job_failure_id"], name: "index_app_issues_on_background_job_failure_id"
    t.index ["fingerprint"], name: "index_app_issues_on_fingerprint", unique: true
    t.index ["instagram_account_id"], name: "index_app_issues_on_instagram_account_id"
    t.index ["instagram_profile_id"], name: "index_app_issues_on_instagram_profile_id"
    t.index ["issue_type"], name: "index_app_issues_on_issue_type"
    t.index ["severity", "last_seen_at"], name: "idx_app_issues_severity_last_seen"
    t.index ["source"], name: "index_app_issues_on_source"
    t.index ["status", "last_seen_at"], name: "idx_app_issues_status_last_seen"
  end

  create_table "background_job_failures", force: :cascade do |t|
    t.string "active_job_id", null: false
    t.text "arguments_json"
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.string "error_class", null: false
    t.text "error_message", null: false
    t.string "failure_kind", default: "runtime", null: false
    t.integer "instagram_account_id"
    t.integer "instagram_profile_id"
    t.string "job_class", null: false
    t.json "metadata"
    t.datetime "occurred_at", null: false
    t.string "provider_job_id"
    t.string "queue_name"
    t.boolean "retryable", default: true, null: false
    t.integer "solid_queue_job_id"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_background_job_failures_on_active_job_id"
    t.index ["failure_kind"], name: "index_background_job_failures_on_failure_kind"
    t.index ["instagram_account_id"], name: "index_background_job_failures_on_instagram_account_id"
    t.index ["instagram_profile_id"], name: "index_background_job_failures_on_instagram_profile_id"
    t.index ["job_class"], name: "index_background_job_failures_on_job_class"
    t.index ["occurred_at"], name: "index_background_job_failures_on_occurred_at"
    t.index ["retryable", "occurred_at"], name: "idx_background_job_failures_retryable_occurred"
  end

  create_table "conversation_peers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.bigint "instagram_account_id", null: false
    t.datetime "last_message_at"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["instagram_account_id", "username"], name: "index_conversation_peers_on_instagram_account_id_and_username", unique: true
    t.index ["instagram_account_id"], name: "index_conversation_peers_on_instagram_account_id"
  end

  create_table "instagram_accounts", force: :cascade do |t|
    t.text "auth_snapshot_json"
    t.boolean "continuous_processing_enabled", default: true, null: false
    t.integer "continuous_processing_failure_count", default: 0, null: false
    t.text "continuous_processing_last_error"
    t.datetime "continuous_processing_last_finished_at"
    t.datetime "continuous_processing_last_heartbeat_at"
    t.datetime "continuous_processing_last_started_at"
    t.datetime "continuous_processing_next_feed_sync_at"
    t.datetime "continuous_processing_next_profile_scan_at"
    t.datetime "continuous_processing_next_story_sync_at"
    t.datetime "continuous_processing_retry_after_at"
    t.string "continuous_processing_state", default: "idle", null: false
    t.text "cookies_json"
    t.datetime "created_at", null: false
    t.datetime "last_synced_at"
    t.text "local_storage_json"
    t.string "login_state", default: "not_authenticated", null: false
    t.text "session_storage_json"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.string "username", null: false
    t.index ["continuous_processing_enabled", "continuous_processing_retry_after_at"], name: "idx_accounts_processing_enabled_retry"
    t.index ["continuous_processing_state", "continuous_processing_last_heartbeat_at"], name: "idx_accounts_processing_state_heartbeat"
    t.index ["username"], name: "index_instagram_accounts_on_username", unique: true
  end

  create_table "instagram_messages", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "direction", default: "outgoing", null: false
    t.text "error_message"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.datetime "sent_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_account_id", "instagram_profile_id", "created_at"], name: "index_instagram_messages_on_account_profile_created_at"
    t.index ["instagram_account_id"], name: "index_instagram_messages_on_instagram_account_id"
    t.index ["instagram_profile_id"], name: "index_instagram_messages_on_instagram_profile_id"
  end

  create_table "instagram_post_entities", force: :cascade do |t|
    t.float "confidence"
    t.datetime "created_at", null: false
    t.string "entity_type", null: false
    t.text "evidence_text"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_post_id", null: false
    t.bigint "instagram_post_insight_id", null: false
    t.string "source_ref"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["instagram_account_id"], name: "index_instagram_post_entities_on_instagram_account_id"
    t.index ["instagram_post_id", "entity_type"], name: "idx_post_entities_post_type"
    t.index ["instagram_post_id"], name: "index_instagram_post_entities_on_instagram_post_id"
    t.index ["instagram_post_insight_id"], name: "index_instagram_post_entities_on_instagram_post_insight_id"
  end

  create_table "instagram_post_insights", force: :cascade do |t|
    t.bigint "ai_analysis_id", null: false
    t.string "author_type"
    t.json "comment_suggestions"
    t.float "confidence"
    t.datetime "created_at", null: false
    t.float "engagement_score"
    t.text "evidence"
    t.text "image_description"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_post_id", null: false
    t.json "raw_analysis"
    t.string "recommended_next_action"
    t.boolean "relevant"
    t.string "sentiment"
    t.json "suggested_actions"
    t.json "topics"
    t.datetime "updated_at", null: false
    t.index ["ai_analysis_id"], name: "index_instagram_post_insights_on_ai_analysis_id"
    t.index ["instagram_account_id", "created_at"], name: "idx_on_instagram_account_id_created_at_ad8c6e2287"
    t.index ["instagram_account_id"], name: "index_instagram_post_insights_on_instagram_account_id"
    t.index ["instagram_post_id", "created_at"], name: "idx_on_instagram_post_id_created_at_926c8d6ea9"
    t.index ["instagram_post_id"], name: "index_instagram_post_insights_on_instagram_post_id"
  end

  create_table "instagram_posts", force: :cascade do |t|
    t.string "ai_model"
    t.string "ai_provider"
    t.json "analysis"
    t.datetime "analyzed_at"
    t.string "author_ig_user_id"
    t.string "author_username"
    t.text "caption"
    t.datetime "created_at", null: false
    t.datetime "detected_at", null: false
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id"
    t.datetime "media_downloaded_at"
    t.string "media_url"
    t.json "metadata"
    t.string "post_kind", default: "post", null: false
    t.datetime "purge_at"
    t.string "shortcode", null: false
    t.string "status", default: "pending", null: false
    t.datetime "taken_at"
    t.datetime "updated_at", null: false
    t.index ["detected_at"], name: "index_instagram_posts_on_detected_at"
    t.index ["instagram_account_id", "shortcode"], name: "index_instagram_posts_on_instagram_account_id_and_shortcode", unique: true
    t.index ["instagram_account_id"], name: "index_instagram_posts_on_instagram_account_id"
    t.index ["instagram_profile_id"], name: "index_instagram_posts_on_instagram_profile_id"
    t.index ["purge_at"], name: "index_instagram_posts_on_purge_at"
    t.index ["status"], name: "index_instagram_posts_on_status"
  end

  create_table "instagram_profile_action_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "active_job_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.text "log_text"
    t.json "metadata"
    t.datetime "occurred_at", null: false
    t.string "queue_name"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.string "trigger_source"
    t.datetime "updated_at", null: false
    t.index ["action", "status"], name: "index_instagram_profile_action_logs_on_action_and_status"
    t.index ["active_job_id"], name: "index_instagram_profile_action_logs_on_active_job_id"
    t.index ["instagram_account_id", "created_at"], name: "idx_profile_action_logs_account_created"
    t.index ["instagram_account_id"], name: "index_instagram_profile_action_logs_on_instagram_account_id"
    t.index ["instagram_profile_id", "created_at"], name: "idx_profile_action_logs_profile_created"
    t.index ["instagram_profile_id"], name: "index_instagram_profile_action_logs_on_instagram_profile_id"
    t.index ["status"], name: "index_instagram_profile_action_logs_on_status"
  end

  create_table "instagram_profile_analyses", force: :cascade do |t|
    t.json "analysis"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.bigint "instagram_profile_id", null: false
    t.json "metadata"
    t.string "model"
    t.text "prompt"
    t.string "provider", default: "xai", null: false
    t.text "response_text"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_profile_id", "created_at"], name: "idx_on_instagram_profile_id_created_at_b96c65e72e"
    t.index ["instagram_profile_id"], name: "index_instagram_profile_analyses_on_instagram_profile_id"
    t.index ["status"], name: "index_instagram_profile_analyses_on_status"
  end

  create_table "instagram_profile_behavior_profiles", force: :cascade do |t|
    t.float "activity_score"
    t.json "behavioral_summary"
    t.datetime "created_at", null: false
    t.bigint "instagram_profile_id", null: false
    t.json "metadata"
    t.datetime "updated_at", null: false
    t.index ["instagram_profile_id"], name: "idx_on_instagram_profile_id_8b2eb319f8", unique: true
  end

  create_table "instagram_profile_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "detected_at", null: false
    t.string "external_id"
    t.bigint "instagram_profile_id", null: false
    t.string "kind", null: false
    t.integer "llm_comment_attempts", default: 0, null: false
    t.datetime "llm_comment_generated_at"
    t.string "llm_comment_job_id"
    t.text "llm_comment_last_error"
    t.json "llm_comment_metadata", default: {}
    t.string "llm_comment_model"
    t.string "llm_comment_provider"
    t.float "llm_comment_relevance_score"
    t.string "llm_comment_status", default: "not_requested", null: false
    t.text "llm_generated_comment"
    t.json "metadata"
    t.datetime "occurred_at"
    t.datetime "updated_at", null: false
    t.index ["instagram_profile_id", "detected_at"], name: "idx_on_instagram_profile_id_detected_at_61620a7860"
    t.index ["instagram_profile_id", "kind", "external_id"], name: "idx_on_instagram_profile_id_kind_external_id_ddff026220", unique: true
    t.index ["instagram_profile_id", "kind", "occurred_at"], name: "idx_profile_events_profile_kind_occurred"
    t.index ["instagram_profile_id"], name: "index_instagram_profile_events_on_instagram_profile_id"
    t.index ["llm_comment_generated_at"], name: "index_instagram_profile_events_on_llm_comment_generated_at"
    t.index ["llm_comment_job_id"], name: "idx_profile_events_llm_comment_job_id"
    t.index ["llm_comment_provider", "llm_comment_generated_at"], name: "idx_on_llm_comment_provider_llm_comment_generated_a_c186e86ca1"
    t.index ["llm_comment_status", "detected_at"], name: "idx_profile_events_llm_status_detected"
  end

  create_table "instagram_profile_history_chunks", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "ends_at"
    t.integer "entry_count", default: 0, null: false
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.json "metadata"
    t.integer "sequence", null: false
    t.datetime "starts_at"
    t.datetime "updated_at", null: false
    t.integer "word_count", default: 0, null: false
    t.index ["instagram_account_id"], name: "index_instagram_profile_history_chunks_on_instagram_account_id"
    t.index ["instagram_profile_id", "created_at"], name: "idx_profile_history_chunks_profile_created"
    t.index ["instagram_profile_id", "sequence"], name: "idx_profile_history_chunks_profile_sequence", unique: true
    t.index ["instagram_profile_id"], name: "index_instagram_profile_history_chunks_on_instagram_profile_id"
  end

  create_table "instagram_profile_insights", force: :cascade do |t|
    t.bigint "ai_analysis_id", null: false
    t.datetime "created_at", null: false
    t.string "emoji_usage"
    t.string "engagement_style"
    t.string "formality"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.datetime "last_refreshed_at", null: false
    t.float "messageability_score"
    t.string "primary_language"
    t.string "profile_type"
    t.json "raw_analysis"
    t.json "secondary_languages"
    t.string "slang_level"
    t.text "summary"
    t.string "tone"
    t.datetime "updated_at", null: false
    t.index ["ai_analysis_id"], name: "index_instagram_profile_insights_on_ai_analysis_id"
    t.index ["instagram_account_id", "created_at"], name: "idx_on_instagram_account_id_created_at_4038a59844"
    t.index ["instagram_account_id"], name: "index_instagram_profile_insights_on_instagram_account_id"
    t.index ["instagram_profile_id", "created_at"], name: "idx_on_instagram_profile_id_created_at_97f0449c46"
    t.index ["instagram_profile_id"], name: "index_instagram_profile_insights_on_instagram_profile_id"
  end

  create_table "instagram_profile_message_strategies", force: :cascade do |t|
    t.bigint "ai_analysis_id", null: false
    t.json "avoid_topics"
    t.json "best_topics"
    t.json "comment_templates"
    t.datetime "created_at", null: false
    t.string "cta_style"
    t.json "donts"
    t.json "dos"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.bigint "instagram_profile_insight_id", null: false
    t.json "opener_templates"
    t.datetime "updated_at", null: false
    t.index ["ai_analysis_id"], name: "index_instagram_profile_message_strategies_on_ai_analysis_id"
    t.index ["instagram_account_id"], name: "idx_on_instagram_account_id_5d2d14cf9d"
    t.index ["instagram_profile_id", "created_at"], name: "idx_profile_message_strategies_profile_created"
    t.index ["instagram_profile_id"], name: "idx_on_instagram_profile_id_b32d0f40d4"
    t.index ["instagram_profile_insight_id"], name: "idx_on_instagram_profile_insight_id_c4a77d6018"
  end

  create_table "instagram_profile_post_comments", force: :cascade do |t|
    t.string "author_username"
    t.text "body", null: false
    t.datetime "commented_at"
    t.datetime "created_at", null: false
    t.bigint "instagram_profile_id", null: false
    t.bigint "instagram_profile_post_id", null: false
    t.json "metadata"
    t.datetime "updated_at", null: false
    t.index ["instagram_profile_id"], name: "index_instagram_profile_post_comments_on_instagram_profile_id"
    t.index ["instagram_profile_post_id", "created_at"], name: "idx_profile_post_comments_post_created"
    t.index ["instagram_profile_post_id"], name: "idx_on_instagram_profile_post_id_48c6b4856d"
  end

  create_table "instagram_profile_posts", force: :cascade do |t|
    t.string "ai_model"
    t.string "ai_provider"
    t.string "ai_status", default: "pending", null: false
    t.json "analysis"
    t.datetime "analyzed_at"
    t.text "caption"
    t.integer "comments_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.datetime "last_synced_at"
    t.integer "likes_count", default: 0, null: false
    t.string "media_url_fingerprint"
    t.json "metadata"
    t.string "permalink"
    t.string "shortcode", null: false
    t.string "source_media_url"
    t.datetime "taken_at"
    t.datetime "updated_at", null: false
    t.index ["ai_status"], name: "index_instagram_profile_posts_on_ai_status"
    t.index ["instagram_account_id"], name: "index_instagram_profile_posts_on_instagram_account_id"
    t.index ["instagram_profile_id", "analyzed_at"], name: "idx_profile_posts_profile_analyzed"
    t.index ["instagram_profile_id", "shortcode"], name: "idx_profile_posts_profile_shortcode", unique: true
    t.index ["instagram_profile_id", "taken_at"], name: "idx_on_instagram_profile_id_taken_at_9b7f9a5d61"
    t.index ["instagram_profile_id"], name: "index_instagram_profile_posts_on_instagram_profile_id"
  end

  create_table "instagram_profile_signal_evidences", force: :cascade do |t|
    t.bigint "ai_analysis_id", null: false
    t.float "confidence"
    t.datetime "created_at", null: false
    t.text "evidence_text"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.bigint "instagram_profile_insight_id", null: false
    t.datetime "occurred_at"
    t.string "signal_type", null: false
    t.string "source_ref"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["ai_analysis_id"], name: "index_instagram_profile_signal_evidences_on_ai_analysis_id"
    t.index ["instagram_account_id"], name: "idx_on_instagram_account_id_8070cdbe38"
    t.index ["instagram_profile_id", "signal_type"], name: "idx_profile_signal_evidence_profile_signal"
    t.index ["instagram_profile_id"], name: "idx_on_instagram_profile_id_07ed343515"
    t.index ["instagram_profile_insight_id"], name: "idx_on_instagram_profile_insight_id_9d9c85e34c"
    t.index ["source_type", "source_ref"], name: "idx_on_source_type_source_ref_7d1ac5370a"
  end

  create_table "instagram_profile_taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "instagram_profile_id", null: false
    t.bigint "profile_tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_profile_id", "profile_tag_id"], name: "idx_profile_tagging_unique", unique: true
    t.index ["instagram_profile_id"], name: "index_instagram_profile_taggings_on_instagram_profile_id"
    t.index ["profile_tag_id"], name: "index_instagram_profile_taggings_on_profile_tag_id"
  end

  create_table "instagram_profiles", force: :cascade do |t|
    t.float "ai_age_confidence"
    t.integer "ai_estimated_age"
    t.string "ai_estimated_gender"
    t.string "ai_estimated_location"
    t.float "ai_gender_confidence"
    t.datetime "ai_last_analyzed_at"
    t.float "ai_location_confidence"
    t.text "ai_persona_summary"
    t.datetime "avatar_synced_at"
    t.string "avatar_url_fingerprint"
    t.text "bio"
    t.boolean "can_message"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.datetime "dm_interaction_checked_at"
    t.string "dm_interaction_reason"
    t.datetime "dm_interaction_retry_after_at"
    t.string "dm_interaction_state"
    t.boolean "following", default: false, null: false
    t.boolean "follows_you", default: false, null: false
    t.string "ig_user_id"
    t.bigint "instagram_account_id", null: false
    t.datetime "last_active_at"
    t.datetime "last_post_at"
    t.datetime "last_story_seen_at"
    t.datetime "last_synced_at"
    t.text "profile_pic_url"
    t.string "restriction_reason"
    t.datetime "story_interaction_checked_at"
    t.string "story_interaction_reason"
    t.datetime "story_interaction_retry_after_at"
    t.string "story_interaction_state"
    t.boolean "story_reaction_available"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["dm_interaction_retry_after_at"], name: "index_instagram_profiles_on_dm_interaction_retry_after_at"
    t.index ["dm_interaction_state"], name: "index_instagram_profiles_on_dm_interaction_state"
    t.index ["ig_user_id"], name: "index_instagram_profiles_on_ig_user_id"
    t.index ["instagram_account_id", "ai_last_analyzed_at"], name: "idx_instagram_profiles_account_last_analyzed"
    t.index ["instagram_account_id", "following", "follows_you"], name: "idx_on_instagram_account_id_following_follows_you_34f570e7b6"
    t.index ["instagram_account_id", "username"], name: "index_instagram_profiles_on_instagram_account_id_and_username", unique: true
    t.index ["instagram_account_id"], name: "index_instagram_profiles_on_instagram_account_id"
    t.index ["story_interaction_retry_after_at"], name: "index_instagram_profiles_on_story_interaction_retry_after_at"
    t.index ["story_interaction_state"], name: "index_instagram_profiles_on_story_interaction_state"
  end

  create_table "instagram_stories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.datetime "expires_at"
    t.string "image_url"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.string "media_type"
    t.string "media_url"
    t.json "metadata"
    t.boolean "processed", default: false, null: false
    t.datetime "processed_at"
    t.string "processing_status", default: "pending", null: false
    t.bigint "source_event_id"
    t.string "story_id", null: false
    t.datetime "taken_at"
    t.datetime "updated_at", null: false
    t.string "video_url"
    t.index ["instagram_account_id", "processed"], name: "index_instagram_stories_on_instagram_account_id_and_processed"
    t.index ["instagram_account_id"], name: "index_instagram_stories_on_instagram_account_id"
    t.index ["instagram_profile_id", "story_id"], name: "index_instagram_stories_on_instagram_profile_id_and_story_id", unique: true
    t.index ["instagram_profile_id"], name: "index_instagram_stories_on_instagram_profile_id"
    t.index ["processing_status"], name: "index_instagram_stories_on_processing_status"
    t.index ["source_event_id"], name: "index_instagram_stories_on_source_event_id"
  end

  create_table "instagram_story_faces", force: :cascade do |t|
    t.json "bounding_box"
    t.datetime "created_at", null: false
    t.float "detector_confidence"
    t.json "embedding"
    t.string "embedding_version"
    t.bigint "instagram_story_id", null: false
    t.bigint "instagram_story_person_id"
    t.float "match_similarity"
    t.json "metadata"
    t.string "role", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_story_id", "created_at"], name: "idx_on_instagram_story_id_created_at_9dea8c75a1"
    t.index ["instagram_story_id"], name: "index_instagram_story_faces_on_instagram_story_id"
    t.index ["instagram_story_person_id"], name: "index_instagram_story_faces_on_instagram_story_person_id"
    t.index ["role"], name: "index_instagram_story_faces_on_role"
  end

  create_table "instagram_story_people", force: :cascade do |t|
    t.integer "appearance_count", default: 0, null: false
    t.json "canonical_embedding"
    t.datetime "created_at", null: false
    t.datetime "first_seen_at"
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_profile_id", null: false
    t.string "label"
    t.datetime "last_seen_at"
    t.json "metadata"
    t.string "role", default: "secondary_person", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_account_id"], name: "index_instagram_story_people_on_instagram_account_id"
    t.index ["instagram_profile_id", "last_seen_at"], name: "idx_on_instagram_profile_id_last_seen_at_7d583e7887"
    t.index ["instagram_profile_id"], name: "index_instagram_story_people_on_instagram_profile_id"
    t.index ["role"], name: "index_instagram_story_people_on_role"
  end

  create_table "profile_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_profile_tags_on_name", unique: true
  end

  create_table "recipients", force: :cascade do |t|
    t.boolean "can_message", default: false, null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.bigint "instagram_account_id", null: false
    t.string "restriction_reason"
    t.boolean "selected", default: false, null: false
    t.string "source", default: "conversation", null: false
    t.boolean "story_visible", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["instagram_account_id", "username"], name: "index_recipients_on_instagram_account_id_and_username", unique: true
    t.index ["instagram_account_id"], name: "index_recipients_on_instagram_account_id"
  end

  create_table "sync_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.bigint "instagram_account_id", null: false
    t.string "kind", default: "follow_graph", null: false
    t.datetime "started_at"
    t.text "stats_json"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_account_id", "created_at"], name: "index_sync_runs_on_instagram_account_id_and_created_at"
    t.index ["instagram_account_id", "kind", "status"], name: "index_sync_runs_on_instagram_account_id_and_kind_and_status"
    t.index ["instagram_account_id"], name: "index_sync_runs_on_instagram_account_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_ingestions", "active_storage_attachments"
  add_foreign_key "active_storage_ingestions", "active_storage_blobs"
  add_foreign_key "active_storage_ingestions", "instagram_accounts"
  add_foreign_key "active_storage_ingestions", "instagram_profiles"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_analyses", "ai_analyses", column: "cached_from_ai_analysis_id"
  add_foreign_key "ai_analyses", "instagram_accounts"
  add_foreign_key "ai_api_calls", "instagram_accounts"
  add_foreign_key "app_issues", "background_job_failures"
  add_foreign_key "app_issues", "instagram_accounts"
  add_foreign_key "app_issues", "instagram_profiles"
  add_foreign_key "conversation_peers", "instagram_accounts"
  add_foreign_key "instagram_messages", "instagram_accounts"
  add_foreign_key "instagram_messages", "instagram_profiles"
  add_foreign_key "instagram_post_entities", "instagram_accounts"
  add_foreign_key "instagram_post_entities", "instagram_post_insights"
  add_foreign_key "instagram_post_entities", "instagram_posts"
  add_foreign_key "instagram_post_insights", "ai_analyses"
  add_foreign_key "instagram_post_insights", "instagram_accounts"
  add_foreign_key "instagram_post_insights", "instagram_posts"
  add_foreign_key "instagram_posts", "instagram_accounts"
  add_foreign_key "instagram_posts", "instagram_profiles"
  add_foreign_key "instagram_profile_action_logs", "instagram_accounts"
  add_foreign_key "instagram_profile_action_logs", "instagram_profiles"
  add_foreign_key "instagram_profile_analyses", "instagram_profiles"
  add_foreign_key "instagram_profile_behavior_profiles", "instagram_profiles"
  add_foreign_key "instagram_profile_events", "instagram_profiles"
  add_foreign_key "instagram_profile_history_chunks", "instagram_accounts"
  add_foreign_key "instagram_profile_history_chunks", "instagram_profiles"
  add_foreign_key "instagram_profile_insights", "ai_analyses"
  add_foreign_key "instagram_profile_insights", "instagram_accounts"
  add_foreign_key "instagram_profile_insights", "instagram_profiles"
  add_foreign_key "instagram_profile_message_strategies", "ai_analyses"
  add_foreign_key "instagram_profile_message_strategies", "instagram_accounts"
  add_foreign_key "instagram_profile_message_strategies", "instagram_profile_insights"
  add_foreign_key "instagram_profile_message_strategies", "instagram_profiles"
  add_foreign_key "instagram_profile_post_comments", "instagram_profile_posts"
  add_foreign_key "instagram_profile_post_comments", "instagram_profiles"
  add_foreign_key "instagram_profile_posts", "instagram_accounts"
  add_foreign_key "instagram_profile_posts", "instagram_profiles"
  add_foreign_key "instagram_profile_signal_evidences", "ai_analyses"
  add_foreign_key "instagram_profile_signal_evidences", "instagram_accounts"
  add_foreign_key "instagram_profile_signal_evidences", "instagram_profile_insights"
  add_foreign_key "instagram_profile_signal_evidences", "instagram_profiles"
  add_foreign_key "instagram_profile_taggings", "instagram_profiles"
  add_foreign_key "instagram_profile_taggings", "profile_tags"
  add_foreign_key "instagram_profiles", "instagram_accounts"
  add_foreign_key "instagram_stories", "instagram_accounts"
  add_foreign_key "instagram_stories", "instagram_profile_events", column: "source_event_id"
  add_foreign_key "instagram_stories", "instagram_profiles"
  add_foreign_key "instagram_story_faces", "instagram_stories"
  add_foreign_key "instagram_story_faces", "instagram_story_people"
  add_foreign_key "instagram_story_people", "instagram_accounts"
  add_foreign_key "instagram_story_people", "instagram_profiles"
  add_foreign_key "recipients", "instagram_accounts"
  add_foreign_key "sync_runs", "instagram_accounts"
end
