import { Controller } from "@hotwired/stimulus"
import { getCableConsumer } from "../lib/cable_consumer"

const MISSING_TEXT_PATTERN = /loading\s+(captured\s+posts|downloaded\s+stories|message\s+history|action\s+history|profile\s+history)/i
const PROFILE_ANALYSIS_JOB_CLASSES = new Set([
  "AnalyzeInstagramProfilePostJob",
  "ProcessPostVisualAnalysisJob",
  "ProcessPostFaceAnalysisJob",
  "ProcessPostOcrAnalysisJob",
  "ProcessPostVideoAnalysisJob",
  "ProcessPostMetadataTaggingJob",
  "FinalizePostAnalysisPipelineJob",
])

export default class extends Controller {
  static values = {
    retryLimit: { type: Number, default: 3 },
    pollMs: { type: Number, default: 900 },
    maxWaitMs: { type: Number, default: 18000 },
    accountId: Number,
    profileId: Number,
  }

  connect() {
    this.frames = Array.from(this.element.querySelectorAll("turbo-frame[id^='profile_'][src]"))
    if (this.frames.length === 0) return

    this.startedAt = Date.now()
    this.frameState = new Map()
    this.operationsConsumer = null
    this.operationsSubscription = null
    this.liveReloadTimer = null
    this.lastLiveReloadAt = 0

    this.frames.forEach((frame) => {
      const src = frame.getAttribute("src")
      this.frameState.set(frame.id, {
        src,
        retries: 0,
        loaded: false,
        autoLoad: frame.getAttribute("loading") !== "lazy",
        lastReloadAt: 0,
      })

      frame.addEventListener("turbo:frame-load", () => this.markLoaded(frame))
      frame.addEventListener("turbo:fetch-request-error", () => this.reloadFrame(frame, "fetch_error"))
    })

    if (this.frames.some((frame) => this.frameState.get(frame.id)?.autoLoad)) {
      this.pollTimer = window.setInterval(() => this.pollFrames(), this.pollMsValue)
      this.pollFrames()
    }
    this.subscribeToOperationsUpdates()
  }

  disconnect() {
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }

    if (this.liveReloadTimer) {
      window.clearTimeout(this.liveReloadTimer)
      this.liveReloadTimer = null
    }

    this.unsubscribeFromOperationsUpdates()
  }

  pollFrames() {
    const now = Date.now()
    const elapsed = now - this.startedAt
    let pending = 0

    this.frames.forEach((frame) => {
      const state = this.frameState.get(frame.id)
      if (!state) return
      if (state.loaded) return
      if (!state.autoLoad) return

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

  subscribeToOperationsUpdates() {
    const accountId = Number(this.accountIdValue)
    if (!Number.isFinite(accountId) || accountId <= 0) return

    try {
      this.operationsConsumer = getCableConsumer()
      if (!this.operationsConsumer?.subscriptions || typeof this.operationsConsumer.subscriptions.create !== "function") return

      this.operationsSubscription = this.operationsConsumer.subscriptions.create(
        {
          channel: "OperationsChannel",
          account_id: accountId,
          include_global: false,
        },
        {
          received: (message) => this.handleOperationsMessage(message),
        }
      )
    } catch (_error) {
      this.operationsConsumer = null
      this.operationsSubscription = null
    }
  }

  unsubscribeFromOperationsUpdates() {
    if (!this.operationsConsumer || !this.operationsSubscription) return

    try {
      this.operationsConsumer.subscriptions.remove(this.operationsSubscription)
    } catch (_error) {
      // Ignore cleanup errors.
    } finally {
      this.operationsSubscription = null
    }
  }

  handleOperationsMessage(message) {
    if (!message || String(message.topic || "") !== "jobs_changed") return

    const payload = message.payload && typeof message.payload === "object" ? message.payload : {}
    const jobClass = String(payload.job_class || "")
    if (!PROFILE_ANALYSIS_JOB_CLASSES.has(jobClass)) return

    const profileId = Number(payload.instagram_profile_id || 0)
    if (Number.isFinite(this.profileIdValue) && this.profileIdValue > 0 && Number.isFinite(profileId) && profileId > 0 && profileId !== this.profileIdValue) {
      return
    }

    this.scheduleCapturedPostsReload("jobs_changed")
  }

  scheduleCapturedPostsReload(reason) {
    const frame = this.capturedPostsFrame()
    if (!frame) return
    const state = this.frameState.get(frame.id)
    if (!state?.loaded) return

    const minIntervalMs = 1100
    const elapsed = Date.now() - this.lastLiveReloadAt
    const waitMs = elapsed >= minIntervalMs ? 120 : (minIntervalMs - elapsed)

    if (this.liveReloadTimer) {
      window.clearTimeout(this.liveReloadTimer)
    }

    this.liveReloadTimer = window.setTimeout(() => {
      this.liveReloadTimer = null
      this.reloadCapturedPostsFrame(frame, reason)
    }, Math.max(120, waitMs))
  }

  reloadCapturedPostsFrame(frame, reason) {
    const state = this.frameState.get(frame.id)
    if (state) {
      state.loaded = false
      state.lastReloadAt = Date.now()
      this.frameState.set(frame.id, state)
    }

    this.lastLiveReloadAt = Date.now()

    try {
      if (typeof frame.reload === "function") {
        frame.reload()
      } else {
        const src = frame.getAttribute("src") || state?.src
        if (!src) return
        const url = new URL(src, window.location.origin)
        url.searchParams.set("_live_reload", String(this.lastLiveReloadAt))
        frame.setAttribute("src", `${url.pathname}${url.search}`)
      }
    } catch (_error) {
      // Ignore live reload errors to keep page interactions intact.
    }

    if (window.__PROFILE_SECTIONS_DEBUG === true && window.console && typeof window.console.debug === "function") {
      window.console.debug(`[profile-sections-loader] live reload ${frame.id} due to ${reason}`)
    }
  }

  capturedPostsFrame() {
    const profileId = Number(this.profileIdValue)
    if (Number.isFinite(profileId) && profileId > 0) {
      const exact = this.element.querySelector(`#profile_captured_posts_${profileId}`)
      if (exact) return exact
    }

    return this.frames.find((frame) => frame.id.includes("captured_posts")) || null
  }
}
