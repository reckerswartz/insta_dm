export function notifyApp(message, type = "notice", options = {}) {
  const text = String(message || "").trim()
  if (!text) return

  document.dispatchEvent(
    new CustomEvent("app:notify", {
      detail: {
        message: text,
        type: String(type || "notice"),
        ttlMs: Number(options.ttlMs) || undefined,
      },
    }),
  )
}

