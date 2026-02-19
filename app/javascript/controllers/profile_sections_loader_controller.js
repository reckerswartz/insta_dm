import { Controller } from "@hotwired/stimulus"

const MISSING_TEXT_PATTERN = /loading\s+(captured\s+posts|downloaded\s+stories|message\s+history|action\s+history|profile\s+history)/i

export default class extends Controller {
  static values = {
    retryLimit: { type: Number, default: 3 },
    pollMs: { type: Number, default: 900 },
    maxWaitMs: { type: Number, default: 18000 },
  }

  connect() {
    this.frames = Array.from(this.element.querySelectorAll("turbo-frame[id^='profile_'][src]"))
    if (this.frames.length === 0) return

    this.startedAt = Date.now()
    this.frameState = new Map()

    this.frames.forEach((frame) => {
      const src = frame.getAttribute("src")
      this.frameState.set(frame.id, {
        src,
        retries: 0,
        loaded: false,
        lastReloadAt: 0,
      })

      // Lazy frame intersection may fail under rapid scroll/headless rendering.
      frame.setAttribute("loading", "eager")

      frame.addEventListener("turbo:frame-load", () => this.markLoaded(frame))
      frame.addEventListener("turbo:fetch-request-error", () => this.reloadFrame(frame, "fetch_error"))
    })

    this.pollTimer = window.setInterval(() => this.pollFrames(), this.pollMsValue)
    this.pollFrames()
  }

  disconnect() {
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  pollFrames() {
    const now = Date.now()
    const elapsed = now - this.startedAt
    let pending = 0

    this.frames.forEach((frame) => {
      const state = this.frameState.get(frame.id)
      if (!state) return
      if (state.loaded) return

      if (this.frameHasResolvedContent(frame)) {
        this.markLoaded(frame)
        return
      }

      pending += 1
      if (state.retries >= this.retryLimitValue) return
      if (now - state.lastReloadAt < 1250) return

      if (this.frameLooksMissing(frame) || elapsed > 2500) {
        this.reloadFrame(frame, this.frameLooksMissing(frame) ? "missing_placeholder" : "stalled")
      }
    })

    if (pending === 0 || elapsed > this.maxWaitMsValue) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  markLoaded(frame) {
    const state = this.frameState.get(frame.id)
    if (!state) return
    state.loaded = true
    this.frameState.set(frame.id, state)
  }

  frameHasResolvedContent(frame) {
    const text = (frame.textContent || "").replace(/\s+/g, " ").trim()
    if (!text) return false
    if (MISSING_TEXT_PATTERN.test(text)) return false

    return true
  }

  frameLooksMissing(frame) {
    const text = (frame.textContent || "").replace(/\s+/g, " ").trim()
    if (!text) return true
    if (MISSING_TEXT_PATTERN.test(text)) return true

    return false
  }

  reloadFrame(frame, reason) {
    const state = this.frameState.get(frame.id)
    if (!state) return
    if (state.retries >= this.retryLimitValue) return

    state.retries += 1
    state.lastReloadAt = Date.now()
    this.frameState.set(frame.id, state)

    try {
      if (typeof frame.reload === "function") {
        frame.reload()
      } else if (state.src) {
        const separator = state.src.includes("?") ? "&" : "?"
        frame.setAttribute("src", `${state.src}${separator}_retry=${state.retries}`)
      }
    } catch (_error) {
      // Ignore to avoid hard-failing profile page behavior.
    }

    if (window.__PROFILE_SECTIONS_DEBUG === true && window.console && typeof window.console.debug === "function") {
      window.console.debug(`[profile-sections-loader] reload ${frame.id} due to ${reason}`)
    }
  }
}
