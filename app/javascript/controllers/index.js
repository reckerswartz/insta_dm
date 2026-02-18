// Import and register all your controllers
import { application } from "./application"

// Import controllers directly
import { default as HelloController } from "./hello_controller"
import { default as AuditMediaModalController } from "./audit-media-modal_controller"
import { default as BackgroundJobFailuresTableController } from "./background_job_failures_table_controller"
import { default as LlmCommentController } from "./llm_comment_controller"
import { default as PostsTableController } from "./posts_table_controller"
import { default as ProfilePostModalController } from "./profile-post-modal_controller"
import { default as ProfileEventsTableController } from "./profile_events_table_controller"
import { default as ProfilesTableController } from "./profiles_table_controller"
import { default as StoryMediaArchiveController } from "./story_media_archive_controller"
import { default as TechnicalDetailsController } from "./technical_details_controller"

// Register controllers
application.register("hello", HelloController)
application.register("audit-media-modal", AuditMediaModalController)
application.register("background-job-failures-table", BackgroundJobFailuresTableController)
application.register("llm-comment", LlmCommentController)
application.register("posts-table", PostsTableController)
application.register("profile-post-modal", ProfilePostModalController)
application.register("profile-events-table", ProfileEventsTableController)
application.register("profiles-table", ProfilesTableController)
application.register("story-media-archive", StoryMediaArchiveController)
application.register("technical-details", TechnicalDetailsController)
