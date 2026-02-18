import { Controller } from "@hotwired/stimulus"
import Hls from "hls.js"

const HLS_MIME_TYPES = new Set([
  "application/vnd.apple.mpegurl",
  "application/x-mpegurl",
  "application/mpegurl",
])

function resolveConstructor(candidate) {
  if (typeof candidate === "function") return candidate
  if (candidate && typeof candidate.default === "function") return candidate.default
  return null
}

const HlsConstructor = resolveConstructor(Hls)

export default class extends Controller {
  static values = {
    autoplay: { type: Boolean, default: false },
    muted: { type: Boolean, default: false },
    lazy: { type: Boolean, default: true },
  }

  connect() {
    this.video = this.element instanceof HTMLVideoElement ? this.element : this.element.querySelector("video")
    if (!this.video) return

    this.currentSource = null
    this.usingHls = false
    this.activated = false

    this.boundLoad = (event) => this.handleLoadEvent(event)
    this.boundClear = () => this.clearSource()

    this.element.addEventListener("video-player:load", this.boundLoad)
    this.element.addEventListener("video-player:clear", this.boundClear)

    this.syncVideoFlags()

    if (this.shouldEagerLoad()) {
      this.activatePlayer()
    } else {
      this.installActivationObservers()
    }
  }

  disconnect() {
    this.element.removeEventListener("video-player:load", this.boundLoad)
    this.element.removeEventListener("video-player:clear", this.boundClear)

    this.teardownActivationObservers()

    this.teardownHls()
  }

  syncVideoFlags() {
    this.video.muted = this.mutedValue
  }

  hasConfiguredSource() {
    const source = this.video.dataset.videoSource || this.video.getAttribute("src") || ""
    return String(source).trim().length > 0
  }

  shouldEagerLoad() {
    if (!this.lazyValue) return true
    if (!this.hasConfiguredSource()) return false
    if (this.autoplayValue) return true
    return this.video.hasAttribute("autoplay")
  }

  installActivationObservers() {
    if (this.activationObserverInstalled) return
    this.activationObserverInstalled = true

    this.boundActivatePlayer = () => this.activatePlayer()
    this.video.addEventListener("pointerdown", this.boundActivatePlayer, { once: true })
    this.video.addEventListener("focus", this.boundActivatePlayer, { once: true })
    this.video.addEventListener("mouseenter", this.boundActivatePlayer, { once: true })
    this.video.addEventListener("play", this.boundActivatePlayer)

    if ("IntersectionObserver" in window) {
      this.intersectionObserver = new IntersectionObserver(
        (entries) => {
          if (entries.some((entry) => entry.isIntersecting || entry.intersectionRatio > 0)) {
            this.activatePlayer()
          }
        },
        { rootMargin: "220px 0px", threshold: 0.01 },
      )
      this.intersectionObserver.observe(this.video)
    }
  }

  teardownActivationObservers() {
    this.activationObserverInstalled = false

    if (this.boundActivatePlayer && this.video) {
      this.video.removeEventListener("pointerdown", this.boundActivatePlayer)
      this.video.removeEventListener("focus", this.boundActivatePlayer)
      this.video.removeEventListener("mouseenter", this.boundActivatePlayer)
      this.video.removeEventListener("play", this.boundActivatePlayer)
    }

    if (this.intersectionObserver) {
      this.intersectionObserver.disconnect()
      this.intersectionObserver = null
    }
  }

  activatePlayer() {
    if (this.activated) return
    this.activated = true

    this.teardownActivationObservers()
    this.loadFromElementAttributes()
  }

  handleLoadEvent(event) {
    this.activatePlayer()

    const detail = event.detail || {}
    const src = detail.src || this.video.dataset.videoSource || this.video.getAttribute("src")
    const contentType = detail.contentType || this.video.dataset.videoContentType || this.video.getAttribute("type")
    const autoplay = typeof detail.autoplay === "boolean" ? detail.autoplay : this.autoplayValue

    if (!src) {
      this.clearSource()
      return
    }

    this.loadSource({ src, contentType, autoplay })
  }

  loadFromElementAttributes() {
    if (!this.activated && this.lazyValue && !this.autoplayValue) return

    const src = this.video.dataset.videoSource || this.video.getAttribute("src") || ""
    const contentType = this.video.dataset.videoContentType || this.video.getAttribute("type") || ""

    if (!src) {
      if (this.currentSource) this.clearSource(false)
      return
    }

    this.loadSource({ src, contentType, autoplay: this.autoplayValue })
  }

  loadSource({ src, contentType = "", autoplay = false }) {
    const normalizedSrc = String(src || "").trim()
    if (!normalizedSrc) {
      this.clearSource()
      return
    }

    const normalizedContentType = String(contentType || "").toLowerCase()
    const useHls = this.isHlsSource(normalizedSrc, normalizedContentType)
    const sourceUnchanged = this.currentSource === normalizedSrc && this.usingHls === useHls

    if (sourceUnchanged) {
      if (autoplay) this.playIfAllowed()
      return
    }

    this.currentSource = normalizedSrc
    this.usingHls = useHls
    this.teardownHls()

    if (useHls) {
      this.loadHlsSource(normalizedSrc, autoplay)
      return
    }

    if (this.video.getAttribute("src") !== normalizedSrc) {
      this.video.setAttribute("src", normalizedSrc)
    }

    this.video.load()
    if (autoplay) this.playIfAllowed()
  }

  loadHlsSource(src, autoplay) {
    if (this.canPlayNativeHls()) {
      this.video.setAttribute("src", src)
      this.video.load()
      if (autoplay) this.playIfAllowed()
      return
    }

    if (!HlsConstructor || !HlsConstructor.isSupported()) {
      this.video.setAttribute("src", src)
      this.video.load()
      if (autoplay) this.playIfAllowed()
      return
    }

    this.video.removeAttribute("src")
    this.video.load()

    const hls = new HlsConstructor({
      enableWorker: true,
      lowLatencyMode: true,
      backBufferLength: 90,
      maxBufferLength: 45,
    })

    this.hls = hls

    hls.attachMedia(this.video)
    hls.on(HlsConstructor.Events.MEDIA_ATTACHED, () => {
      if (this.hls !== hls) return
      hls.loadSource(src)
    })

    if (autoplay) {
      hls.on(HlsConstructor.Events.MANIFEST_PARSED, () => {
        if (this.hls !== hls) return
        this.playIfAllowed()
      })
    }

    hls.on(HlsConstructor.Events.ERROR, (_event, data) => {
      if (!data?.fatal || this.hls !== hls) return

      if (data.type === HlsConstructor.ErrorTypes.NETWORK_ERROR) {
        hls.startLoad()
      } else if (data.type === HlsConstructor.ErrorTypes.MEDIA_ERROR) {
        hls.recoverMediaError()
      } else {
        this.teardownHls()
        this.video.setAttribute("src", src)
        this.video.load()
        if (autoplay) this.playIfAllowed()
      }
    })
  }

  clearSource(resetState = true) {
    this.teardownHls()
    this.video.pause()
    this.video.removeAttribute("src")
    this.video.removeAttribute("data-video-source")
    this.video.removeAttribute("data-video-content-type")
    this.video.load()

    if (resetState) {
      this.currentSource = null
      this.usingHls = false
    }
  }

  teardownHls() {
    if (!this.hls) return
    this.hls.destroy()
    this.hls = null
  }

  isHlsSource(src, contentType) {
    if (HLS_MIME_TYPES.has(contentType)) return true
    return src.split("?")[0].toLowerCase().endsWith(".m3u8")
  }

  canPlayNativeHls() {
    return this.video.canPlayType("application/vnd.apple.mpegurl") !== ""
  }

  playIfAllowed() {
    const playPromise = this.video.play()
    if (playPromise && typeof playPromise.catch === "function") {
      playPromise.catch(() => {})
    }
  }
}
