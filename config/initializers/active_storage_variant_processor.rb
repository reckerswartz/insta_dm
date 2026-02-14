# Prefer libvips when available (fast + low memory). Fall back silently when the shared library
# isn't installed in the current environment (common in local dev).
begin
  require "vips"
  Rails.application.config.active_storage.variant_processor = :vips
rescue LoadError
  # Keep default processor (usually MiniMagick) or "none" if variants aren't used.
end

