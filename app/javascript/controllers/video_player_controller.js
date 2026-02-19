import { Controller } from "@hotwired/stimulus"
import Plyr from "plyr"

const PLAYER_INIT_QUEUE = []
let playerInitQueueScheduled = false

function scheduleIdleTask(callback) {
  if (typeof window !== "undefined" && "requestIdleCallback" in window) {
    window.requestIdleCallback(() => callback(), { timeout: 400 })
    return
  }

  setTimeout(callback, 0)
}

function queuePlayerInitialization(task) {
  PLAYER_INIT_QUEUE.push(task)
  if (playerInitQueueScheduled) return

  playerInitQueueScheduled = true
  scheduleIdleTask(function runNext() {
    playerInitQueueScheduled = false
    const nextTask = PLAYER_INIT_QUEUE.shift()
    if (typeof nextTask === "function") {
      nextTask()
    }

    if (PLAYER_INIT_QUEUE.length > 0) {
      playerInitQueueScheduled = true
      scheduleIdleTask(runNext)
    }
  })
}

export default class extends Controller {
  static values = {
    autoplay: { type: Boolean, default: false },
    muted: { type: Boolean, default: false },
    static: { type: Boolean, default: false },
    posterUrl: String,
    loadOnPlay: { type: Boolean, default: true },
    deferUntilVisible: { type: Boolean, default: false },
    metadataTimeoutMs: { type: Number, default: 9000 },
    preload: { type: String, default: "none" },
  }

  connect() {
    this.video = this.element instanceof HTMLVideoElement ? this.element : this.element.querySelector("video")
    if (!this.video) return

    this.currentLoadToken = 0
    this.pendingDeferredLoad = null
    this.pendingLoadConfig = null
    this.visibilityObserver = null
    this.metadataWaitCleanup = null
    this.playerInitQueued = false
    this.loadOnPlayInFlight = false

    this.boundLoad = (event) => this.handleLoadEvent(event)
    this.boundClear = () => this.clearSource()
    this.boundPlayIntent = (event) => this.handlePlayIntent(event)
    this.boundClickIntent = () => this.handleClickIntent()
    this.boundPlaying = () => this.handlePlaying()
    this.boundGlobalPlay = (event) => this.handleGlobalPlay(event)
    this.eventTargets = this.video === this.element ? [this.video] : [this.element, this.video]
    this.eventTargets.forEach((target) => {
      target.addEventListener("video-player:load", this.boundLoad)
      target.addEventListener("video-player:clear", this.boundClear)
    })
    this.video.addEventListener("play", this.boundPlayIntent)
    this.video.addEventListener("click", this.boundClickIntent)
    this.video.addEventListener("playing", this.boundPlaying)
    window.addEventListener("video-player:global-play", this.boundGlobalPlay)

    this.syncVideoFlags()
    this.loadFromElementAttributes()
  }

  disconnect() {
    this.eventTargets?.forEach((target) => {
      target.removeEventListener("video-player:load", this.boundLoad)
      target.removeEventListener("video-player:clear", this.boundClear)
    })
    this.video?.removeEventListener("play", this.boundPlayIntent)
    this.video?.removeEventListener("click", this.boundClickIntent)
    this.video?.removeEventListener("playing", this.boundPlaying)
    window.removeEventListener("video-player:global-play", this.boundGlobalPlay)
    this.eventTargets = null
    this.cancelDeferredVisibilityLoad()
    this.pendingDeferredLoad = null
    this.pendingLoadConfig = null
    this.clearMetadataWait()
    this.teardownPlayer()
  }

  ensurePlayer() {
    if (this.player || !this.video) return
    try {
      this.player = new Plyr(this.video, {
        autoplay: false,
        clickToPlay: true,
        muted: this.mutedValue,
        controls: [
          "play-large",
          "play",
          "progress",
          "current-time",
          "mute",
          "volume",
          "settings",
          "pip",
          "fullscreen",
        ],
      })
      this.dispatchState("player_ready")
    } catch (_error) {
      this.player = null
      this.dispatchState("player_error")
    }
  }

  schedulePlayerInitialization() {
    if (this.player || this.playerInitQueued || !this.video) return
    this.playerInitQueued = true

    queuePlayerInitialization(() => {
      this.playerInitQueued = false
      if (!this.isConnected || !this.video) return
      if (this.video.readyState < HTMLMediaElement.HAVE_METADATA) return
      this.ensurePlayer()
    })
  }

  teardownPlayer() {
    if (!this.player) return
    this.player.destroy?.()
    this.player = null
  }

  syncVideoFlags(preloadOverride = null) {
    if (!this.video) return
    this.video.muted = this.mutedValue
    this.video.playsInline = true
    this.video.setAttribute("playsinline", "")
    const desiredPreload = preloadOverride || this.video.getAttribute("preload") || this.preloadValue
    if (this.loadOnPlayValue && !this.video.getAttribute("src")) {
      this.video.setAttribute("preload", "none")
      return
    }
    this.video.setAttribute("preload", this.normalizePreload(desiredPreload))
  }

  handleLoadEvent(event) {
    const detail = event.detail || {}
    const src = detail.src || this.video.dataset.videoSource || this.video.getAttribute("src") || ""
    const contentType = detail.contentType || this.video.dataset.videoContentType || this.video.getAttribute("type") || ""
    const posterUrl = detail.posterUrl || this.video.dataset.videoPosterUrl || this.posterUrlValue || ""
    const staticVideo = this.toBoolean(detail.staticVideo, this.toBoolean(this.video.dataset.videoStatic, this.staticValue))
    const autoplay = this.toBoolean(detail.autoplay, this.autoplayValue)
    const deferUntilVisible = this.toBoolean(detail.deferUntilVisible, this.deferUntilVisibleValue)
    const immediate = this.toBoolean(detail.immediate, false)
    const preload = detail.preload || this.video.getAttribute("preload") || (this.loadOnPlayValue ? "none" : this.preloadValue)

    this.video.dataset.videoSource = src
    this.video.dataset.videoContentType = contentType
    this.video.dataset.videoPosterUrl = posterUrl
    this.video.dataset.videoStatic = staticVideo ? "true" : "false"

    if (!src) {
      this.clearSource()
      return
    }

    this.requestSourceLoad({ src, posterUrl, staticVideo, autoplay, deferUntilVisible, immediate, preload })
  }

  loadFromElementAttributes() {
    const src = this.video.dataset.videoSource || this.video.getAttribute("src") || ""
    const posterUrl = this.video.dataset.videoPosterUrl || this.posterUrlValue || ""
    const staticVideo = this.toBoolean(this.video.dataset.videoStatic, this.staticValue)
    if (!String(src).trim()) {
      this.applyPresentation({ posterUrl, staticVideo })
      return
    }

    this.requestSourceLoad({
      src,
      posterUrl,
      staticVideo,
      autoplay: this.autoplayValue,
      deferUntilVisible: this.deferUntilVisibleValue,
      immediate: false,
      preload: this.video.getAttribute("preload") || (this.loadOnPlayValue ? "none" : this.preloadValue),
    })
  }

  requestSourceLoad({
    src,
    posterUrl = "",
    staticVideo = false,
    autoplay = false,
    deferUntilVisible = this.deferUntilVisibleValue,
    immediate = false,
    preload = this.preloadValue,
  }) {
    const normalizedSrc = String(src || "").trim()
    if (!normalizedSrc) {
      this.clearSource()
      return
    }

    const loadConfig = {
      src: normalizedSrc,
      posterUrl: String(posterUrl || "").trim(),
      staticVideo: Boolean(staticVideo),
      autoplay: Boolean(autoplay),
      deferUntilVisible: Boolean(deferUntilVisible),
      immediate: Boolean(immediate),
      preload: this.normalizePreload(preload),
    }

    this.applyPresentation({ posterUrl: loadConfig.posterUrl, staticVideo: loadConfig.staticVideo })

    if (this.loadOnPlayValue && !loadConfig.autoplay && !loadConfig.immediate) {
      this.deferUntilPlay(loadConfig)
      return
    }

    if (loadConfig.deferUntilVisible && !loadConfig.immediate && !this.isVideoVisible()) {
      this.deferUntilVisibleLoad(loadConfig)
      this.dispatchState("deferred", { src: loadConfig.src })
      return
    }

    this.cancelDeferredVisibilityLoad()
    this.loadNow(loadConfig)
  }

  loadNow(loadConfig) {
    this.pendingDeferredLoad = null
    this.pendingLoadConfig = null
    this.currentLoadToken += 1
    const token = this.currentLoadToken

    this.clearMetadataWait()
    this.syncVideoFlags(loadConfig.preload)

    const srcChanged = this.video.getAttribute("src") !== loadConfig.src
    if (srcChanged) {
      this.video.setAttribute("src", loadConfig.src)
      this.safeLoadVideo()
    }

    if (this.video.readyState >= HTMLMediaElement.HAVE_METADATA) {
      this.handleMetadataReady(token, loadConfig)
      return
    }

    this.waitForMetadata(token, loadConfig)
  }

  waitForMetadata(token, loadConfig) {
    this.dispatchState("loading", { src: loadConfig.src })

    const onMetadata = () => this.handleMetadataReady(token, loadConfig)
    const onFailure = () => this.handleMetadataUnavailable(token, loadConfig, "media_error")

    this.video.addEventListener("loadedmetadata", onMetadata, { once: true })
    this.video.addEventListener("error", onFailure, { once: true })
    this.video.addEventListener("abort", onFailure, { once: true })

    const timeoutMs = Math.max(1200, Number(this.metadataTimeoutMsValue || 9000))
    const timeoutId = setTimeout(() => {
      this.handleMetadataUnavailable(token, loadConfig, "metadata_timeout")
    }, timeoutMs)

    this.metadataWaitCleanup = () => {
      clearTimeout(timeoutId)
      this.video.removeEventListener("loadedmetadata", onMetadata)
      this.video.removeEventListener("error", onFailure)
      this.video.removeEventListener("abort", onFailure)
      this.metadataWaitCleanup = null
    }
  }

  handleMetadataReady(token, loadConfig) {
    if (token !== this.currentLoadToken || !this.video) return
    this.clearMetadataWait()
    this.dispatchState("ready", { src: loadConfig.src })
    this.schedulePlayerInitialization()
    if (loadConfig.autoplay && !loadConfig.staticVideo) this.playIfAllowed()
  }

  handleMetadataUnavailable(token, loadConfig, reason) {
    if (token !== this.currentLoadToken || !this.video) return
    this.clearMetadataWait()
    this.teardownPlayer()
    this.dispatchState("fallback", { src: loadConfig.src, reason })
  }

  clearSource() {
    if (!this.video) return
    this.currentLoadToken += 1
    this.cancelDeferredVisibilityLoad()
    this.pendingDeferredLoad = null
    this.pendingLoadConfig = null
    this.clearMetadataWait()
    this.video.pause()

    const hadSource = this.video.hasAttribute("src") || Boolean(this.video.currentSrc)
    this.video.removeAttribute("src")
    this.video.removeAttribute("poster")
    this.video.removeAttribute("data-video-source")
    this.video.removeAttribute("data-video-content-type")
    this.video.removeAttribute("data-video-poster-url")
    this.video.removeAttribute("data-video-static")
    if (hadSource) this.safeLoadVideo()
    this.toggleStaticShell(false)
    this.syncVideoFlags("none")
    this.dispatchState("cleared")
  }

  applyPresentation({ posterUrl, staticVideo }) {
    const poster = String(posterUrl || "").trim()
    if (poster.length > 0) {
      this.video.setAttribute("poster", poster)
    } else {
      this.video.removeAttribute("poster")
    }

    this.video.setAttribute("preload", this.normalizePreload(this.video.getAttribute("preload") || this.preloadValue))
    this.toggleStaticShell(staticVideo)
  }

  toggleStaticShell(enabled) {
    const shell = this.video.closest(".story-video-player-shell")
    if (!shell) return
    shell.classList.toggle("story-video-static-preview", Boolean(enabled))
  }

  playIfAllowed() {
    const playPromise = this.video.play()
    if (playPromise && typeof playPromise.catch === "function") {
      playPromise.catch(() => {})
    }
  }

  handlePlayIntent() {
    if (!this.pendingLoadConfig || this.loadOnPlayInFlight) return

    this.loadOnPlayInFlight = true
    this.handlePlaying()
    this.video.pause()

    const loadConfig = {
      ...this.pendingLoadConfig,
      autoplay: true,
      immediate: true,
      deferUntilVisible: false,
      preload: "metadata",
    }

    this.pendingLoadConfig = null
    this.cancelDeferredVisibilityLoad()
    this.loadNow(loadConfig)
    this.loadOnPlayInFlight = false
  }

  handleClickIntent() {
    if (!this.pendingLoadConfig || this.loadOnPlayInFlight) return
    this.handlePlayIntent()
  }

  handlePlaying() {
    if (!this.video) return
    window.dispatchEvent(new CustomEvent("video-player:global-play", {
      detail: { source: this.video },
    }))
  }

  handleGlobalPlay(event) {
    const source = event?.detail?.source
    if (!source || source === this.video || !this.video) return
    if (!this.video.paused) this.video.pause()
  }

  deferUntilVisibleLoad(loadConfig) {
    this.pendingDeferredLoad = loadConfig
    this.cancelDeferredVisibilityLoad()

    if (typeof window === "undefined" || !("IntersectionObserver" in window)) {
      scheduleIdleTask(() => {
        if (!this.isConnected || !this.pendingDeferredLoad) return
        const deferred = this.pendingDeferredLoad
        this.pendingDeferredLoad = null
        this.loadNow(deferred)
      })
      return
    }

    this.visibilityObserver = new IntersectionObserver((entries) => {
      const hasVisibleEntry = entries.some((entry) => entry.isIntersecting || entry.intersectionRatio > 0)
      if (!hasVisibleEntry || !this.pendingDeferredLoad) return

      const deferred = this.pendingDeferredLoad
      this.pendingDeferredLoad = null
      this.cancelDeferredVisibilityLoad()
      this.loadNow(deferred)
    }, {
      root: null,
      rootMargin: "240px 0px",
      threshold: 0.01,
    })

    this.visibilityObserver.observe(this.video)
  }

  cancelDeferredVisibilityLoad() {
    if (this.visibilityObserver) {
      this.visibilityObserver.disconnect()
      this.visibilityObserver = null
    }
  }

  clearMetadataWait() {
    if (typeof this.metadataWaitCleanup === "function") {
      this.metadataWaitCleanup()
    }
    this.metadataWaitCleanup = null
  }

  isVideoVisible() {
    if (!this.video || !this.video.isConnected) return false
    const rect = this.video.getBoundingClientRect()
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0
    const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0
    if (rect.width <= 0 || rect.height <= 0) return false
    if (rect.bottom < -120 || rect.top > viewportHeight + 120) return false
    if (rect.right < -120 || rect.left > viewportWidth + 120) return false
    return true
  }

  safeLoadVideo() {
    try {
      this.video.load()
    } catch (_error) {}
  }

  dispatchState(state, detail = {}) {
    if (!this.video) return
    this.video.dataset.videoPlayerState = state
    this.video.dispatchEvent(new CustomEvent("video-player:state", {
      detail: { state, ...detail },
    }))
  }

  normalizePreload(raw) {
    const value = String(raw || "").trim().toLowerCase()
    if (["none", "metadata", "auto"].includes(value)) return value
    return "metadata"
  }

  deferUntilPlay(loadConfig) {
    this.pendingLoadConfig = {
      ...loadConfig,
      immediate: true,
      autoplay: false,
      deferUntilVisible: false,
      preload: "metadata",
    }

    this.cancelDeferredVisibilityLoad()
    this.clearMetadataWait()
    if (this.video.getAttribute("src")) {
      this.video.removeAttribute("src")
      this.safeLoadVideo()
    }
    this.syncVideoFlags("none")
    this.dispatchState("waiting_for_play", { src: loadConfig.src })
  }

  toBoolean(value, fallback = false) {
    if (typeof value === "boolean") return value
    if (typeof value === "string") {
      const normalized = value.trim().toLowerCase()
      if (["1", "true", "yes", "on"].includes(normalized)) return true
      if (["0", "false", "no", "off", ""].includes(normalized)) return false
    }
    return Boolean(fallback)
  }
}
