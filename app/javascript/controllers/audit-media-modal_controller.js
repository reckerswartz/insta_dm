import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "title", "image", "video", "videoShell", "meta", "download", "appProfileLink", "instagramProfileLink"]

  connect() {
    this.hiddenHandler = () => this.clearVideoPlayer()
    if (!this.hasModalTarget) return

    this.bootstrapModal = window.bootstrap?.Modal?.getOrCreateInstance(this.modalTarget)
    this.modalTarget.addEventListener("hidden.bs.modal", this.hiddenHandler)
  }

  disconnect() {
    if (this.hasModalTarget) {
      this.modalTarget.removeEventListener("hidden.bs.modal", this.hiddenHandler)
    }
    this.clearVideoPlayer()
    this.bootstrapModal?.dispose?.()
    this.bootstrapModal = null
  }

  open(event) {
    event.preventDefault()
    const data = event.currentTarget.dataset
    const mediaUrl = data.mediaUrl || ""
    const downloadUrl = data.mediaDownloadUrl || mediaUrl || "#"
    const contentType = (data.mediaContentType || "").toLowerCase()
    const previewImageUrl = data.mediaPreviewImageUrl || ""
    const staticVideo = this.toBoolean(data.videoStaticFrameOnly)
    const profileId = (data.profileId || "").trim()
    const profile = (data.profileUsername || "").trim()
    const activity = data.activityKind || "-"
    const occurredAt = data.occurredAt || "-"

    this.titleTarget.textContent = `Media • ${activity.replaceAll("_", " ")}`
    if (profileId.length > 0) {
      this.appProfileLinkTarget.textContent = `@${profile || profileId}`
      this.appProfileLinkTarget.href = `/instagram_profiles/${encodeURIComponent(profileId)}`
    } else {
      this.appProfileLinkTarget.textContent = profile.length > 0 ? `@${profile}` : "-"
      this.appProfileLinkTarget.href = "#"
    }

    if (profile.length > 0) {
      this.instagramProfileLinkTarget.textContent = "IG"
      this.instagramProfileLinkTarget.href = `https://www.instagram.com/${encodeURIComponent(profile)}/`
    } else {
      this.instagramProfileLinkTarget.textContent = "-"
      this.instagramProfileLinkTarget.href = "#"
    }
    this.metaTarget.textContent = `Type: ${contentType || "unknown"} | Time: ${occurredAt}`

    this.downloadTarget.href = downloadUrl

    const mediaPath = mediaUrl.split("?")[0].toLowerCase()
    const isVideo = contentType.startsWith("video/") ||
      mediaPath.endsWith(".mp4") ||
      mediaPath.endsWith(".mov") ||
      mediaPath.endsWith(".webm") ||
      mediaPath.endsWith(".m3u8")

    if (isVideo) {
      this.videoTarget.dataset.videoSource = mediaUrl
      this.videoTarget.dataset.videoContentType = contentType
      this.videoTarget.dataset.videoPosterUrl = previewImageUrl
      this.videoTarget.dataset.videoStatic = staticVideo ? "true" : "false"
      this.videoTarget.dispatchEvent(
        new CustomEvent("video-player:load", {
          detail: { src: mediaUrl, contentType, posterUrl: previewImageUrl, staticVideo, autoplay: false, immediate: false, preload: "none" },
        }),
      )

      if (this.hasVideoShellTarget) {
        this.videoShellTarget.classList.remove("d-none")
      } else {
        this.videoTarget.classList.remove("d-none")
      }
      this.imageTarget.removeAttribute("src")
      this.imageTarget.classList.add("d-none")
    } else {
      this.clearVideoPlayer()
      this.imageTarget.src = mediaUrl
      this.imageTarget.classList.remove("d-none")
    }

    this.bootstrapModal?.show()
  }

  clearVideoPlayer() {
    if (this.hasVideoTarget) this.videoTarget.dispatchEvent(new CustomEvent("video-player:clear"))
    if (this.hasVideoShellTarget) {
      this.videoShellTarget.classList.add("d-none")
    } else {
      this.videoTarget.classList.add("d-none")
    }
  }

  toBoolean(raw) {
    if (typeof raw === "boolean") return raw
    const value = String(raw || "").trim().toLowerCase()
    return ["1", "true", "yes", "on"].includes(value)
  }
}
