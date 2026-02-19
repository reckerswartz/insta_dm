# Prevent FFmpeg preview generation from reading stdin when services run in a
# background process group (for example under `bin/dev`).
Rails.application.config.active_storage.video_preview_arguments = "-nostdin -y -vframes 1 -f image2"
