import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "title", "image", "video", "meta", "download", "appProfileLink", "instagramProfileLink"]

  open(event) {
    event.preventDefault()
    const data = event.currentTarget.dataset
    const mediaUrl = data.mediaUrl || ""
    const downloadUrl = data.mediaDownloadUrl || mediaUrl || "#"
    const contentType = (data.mediaContentType || "").toLowerCase()
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

    const isVideo = contentType.startsWith("video/")

    if (isVideo) {
      this.videoTarget.src = mediaUrl
      this.videoTarget.style.display = "block"
      this.imageTarget.removeAttribute("src")
      this.imageTarget.style.display = "none"
    } else {
      this.imageTarget.src = mediaUrl
      this.imageTarget.style.display = "block"
      this.videoTarget.pause()
      this.videoTarget.removeAttribute("src")
      this.videoTarget.style.display = "none"
    }

    this.dialogTarget.showModal()
  }

  close() {
    this.videoTarget.pause()
    this.dialogTarget.close()
  }
}
