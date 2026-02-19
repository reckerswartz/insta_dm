import { Controller } from "@hotwired/stimulus"

const MAX_JSON_PAYLOAD_BYTES = 120000
const MAX_RENDERED_ITEMS = 24

export default class extends Controller {
  static targets = [
    "modal",
    "title",
    "image",
    "video",
    "videoShell",
    "caption",
    "stats",
    "comments",
    "meta",
    "generation",
    "download",
    "permalink",
    "suggestions",
    "faces",
  ]

  connect() {
    this.forwardUrl = ""
    this.renderToken = 0
    this.pendingRenderId = null
    this.forwardClickHandler = (event) => this.forwardSuggestion(event)
    this.hiddenHandler = () => this.handleModalHidden()
    this.shownHandler = () => this.handleModalShown()

    if (this.hasSuggestionsTarget) this.suggestionsTarget.addEventListener("click", this.forwardClickHandler)
    if (this.hasModalTarget) {
      this.bootstrapModal = window.bootstrap?.Modal?.getOrCreateInstance(this.modalTarget)
      this.modalTarget.addEventListener("hidden.bs.modal", this.hiddenHandler)
      this.modalTarget.addEventListener("shown.bs.modal", this.shownHandler)
    }
  }

  disconnect() {
    if (this.pendingRenderId) window.cancelAnimationFrame(this.pendingRenderId)
    this.pendingRenderId = null
    if (this.hasSuggestionsTarget) this.suggestionsTarget.removeEventListener("click", this.forwardClickHandler)
    if (this.hasModalTarget) {
      this.modalTarget.removeEventListener("hidden.bs.modal", this.hiddenHandler)
      this.modalTarget.removeEventListener("shown.bs.modal", this.shownHandler)
    }
    this.hideModalImmediately()
    this.bootstrapModal?.dispose?.()
    this.bootstrapModal = null
  }

  open(event) {
    event.preventDefault()
    const source = event.currentTarget
    if (!source) return

    try {
      const data = { ...source.dataset }
      this.forwardUrl = data.forwardUrl || ""
      this.renderToken += 1
      const currentToken = this.renderToken

      this.renderLoadingState(data)
      if (!this.safeShowModal()) {
        return
      }

      if (this.pendingRenderId) window.cancelAnimationFrame(this.pendingRenderId)
      this.pendingRenderId = window.requestAnimationFrame(() => {
        this.pendingRenderId = null
        if (currentToken !== this.renderToken) return
        this.renderPayload(data)
      })
    } catch (error) {
      window.__profilePostModalLastError = error?.message || "Unable to initialize post modal"
      this.hideModalImmediately()
    }
  }

  renderLoadingState(data) {
    this.titleTarget.textContent = data.shortcode || "Post"
    this.captionTarget.textContent = "Loading..."
    this.statsTarget.textContent = "Loading post metadata..."
    this.metaTarget.textContent = "Loading model metadata..."
    this.generationTarget.textContent = "Preparing modal content..."

    this.commentsTarget.innerHTML = "<p class='meta'>Loading comments...</p>"
    this.suggestionsTarget.innerHTML = "<p class='meta'>Loading suggested comments...</p>"
    if (this.hasFacesTarget) this.facesTarget.innerHTML = "<p class='meta'>Loading face summary...</p>"

    this.downloadTarget.href = data.downloadUrl || data.imageUrl || "#"
    this.permalinkTarget.href = data.permalink || "#"
    this._renderMedia(data)
  }

  handleModalHidden() {
    this.renderToken += 1
    if (this.pendingRenderId) window.cancelAnimationFrame(this.pendingRenderId)
    this.pendingRenderId = null
    this.clearMediaVideo()
  }

  handleModalShown() {
    const focusTarget = this.modalTarget.querySelector("[data-profile-post-modal-initial-focus]")
    focusTarget?.focus?.()
  }

  renderPayload(data) {
    try {
      this.captionTarget.textContent = data.caption || "-"
      this.statsTarget.textContent = `Likes: ${data.likes || 0} | Comments: ${data.commentsCount || 0} | Taken: ${data.takenAt || "-"}`
      this.metaTarget.textContent = `Provider: ${data.aiProvider || "-"} | Model: ${data.aiModel || "-"} | AI status: ${data.aiStatus || "pending"}`

      const fallback = String(data.commentGenFallback || "").toLowerCase() === "true"
      const status = data.commentGenStatus || "unknown"
      const source = data.commentGenSource || "unknown"
      const err = data.commentGenError || ""
      this.generationTarget.textContent = fallback
        ? `Comment generation: fallback (${status})${err ? ` | Error: ${err}` : ""}`
        : `Comment generation: ${source} (${status})`

      const comments = this._safeJson(data.commentsJson, data.comments).slice(0, MAX_RENDERED_ITEMS)
      const suggestions = this._safeJson(data.suggestionsJson, data.suggestions).slice(0, MAX_RENDERED_ITEMS)
      const faceSummary = this._safeObject(data.faceSummaryJson)

      this.commentsTarget.innerHTML = this._listHtml(comments, "No comments captured")
      this.suggestionsTarget.innerHTML = this._suggestionsHtml(suggestions)
      if (this.hasFacesTarget) {
        this.facesTarget.innerHTML = this._faceSummaryHtml(faceSummary)
      }
    } catch (error) {
      window.__profilePostModalLastError = error?.message || "Failed to render profile post modal"
      this.commentsTarget.innerHTML = "<p class='meta'>Unable to render post details. Please try again.</p>"
      this.suggestionsTarget.innerHTML = ""
      if (this.hasFacesTarget) this.facesTarget.innerHTML = ""
    }
  }

  safeShowModal() {
    if (!this.hasModalTarget || !this.bootstrapModal) return false

    try {
      this.bootstrapModal.show()
      return true
    } catch (error) {
      window.__profilePostModalLastError = error?.message || "Unable to open post modal"
      this.hideModalImmediately()
      return false
    }
  }

  hideModalImmediately() {
    if (!this.hasModalTarget) return
    try {
      this.bootstrapModal?.hide?.()
    } catch (_) {
      this.modalTarget.classList.remove("show")
      this.modalTarget.style.display = "none"
      this.modalTarget.setAttribute("aria-hidden", "true")
    }
    this.clearMediaVideo()
  }

  _safeJson(raw, fallback = []) {
    const payload = String(raw || "")
    if (!payload.length) return Array.isArray(fallback) ? fallback : []
    if (payload.length > MAX_JSON_PAYLOAD_BYTES) return []

    try {
      const parsed = JSON.parse(payload)
      return Array.isArray(parsed) ? parsed : []
    } catch (_) {
      return []
    }
  }

  _safeObject(raw) {
    const payload = String(raw || "{}")
    if (payload.length > MAX_JSON_PAYLOAD_BYTES) return {}

    try {
      const parsed = JSON.parse(payload)
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
    } catch (_) {
      return {}
    }
  }

  _listHtml(items, emptyText) {
    if (!items.length) return `<p class='meta'>${emptyText}</p>`
    return `<ul class='issue-list'>${items.map((v) => `<li>${this._escape(String(v))}</li>`).join("")}</ul>`
  }

  _suggestionsHtml(items) {
    if (!items.length) return "<p class='meta'>No AI suggestions yet</p>"

    return `<ul class='issue-list'>${items.map((v, i) => {
      const txt = this._escape(String(v))
      return `<li><div>${txt}</div><div class="suggestion-action-row"><button type="button" class="btn btn-sm btn-primary" data-forward-comment="${txt}" data-forward-idx="${i}">Forward Comment</button></div></li>`
    }).join("")}</ul>`
  }

  _faceSummaryHtml(payload) {
    const participants = Array.isArray(payload.participants) ? payload.participants : []
    const totalFaces = Number(payload.face_count || 0)
    const ownerFaces = Number(payload.owner_faces_count || 0)
    const recurringFaces = Number(payload.recurring_faces_count || 0)
    const source = String(payload.detection_source || "")
    const participantSummary = String(payload.participant_summary || "")
    const postPeopleScope = String(payload.post_people_scope || "")
    const uniquePeopleCount = Number(payload.unique_people_count || 0)
    const linkedFaceCount = Number(payload.linked_face_count || 0)
    const minMatchConfidence = Number(payload.min_match_confidence || 0)

    if (totalFaces <= 0 && participants.length === 0) {
      return "<p class='meta'>No detected faces for this post yet.</p>"
    }

    const lines = [
      `Faces: <strong>${this._escape(String(totalFaces))}</strong>`,
      linkedFaceCount > 0 ? `Linked: <strong>${this._escape(String(linkedFaceCount))}</strong>` : "",
      ownerFaces > 0 ? `Owner matches: <strong>${this._escape(String(ownerFaces))}</strong>` : "",
      recurringFaces > 0 ? `Recurring: <strong>${this._escape(String(recurringFaces))}</strong>` : "",
      uniquePeopleCount > 0 ? `People in post: <strong>${this._escape(String(uniquePeopleCount))}</strong>` : "",
      postPeopleScope ? `Scope: <strong>${this._escape(postPeopleScope.replaceAll("_", " "))}</strong>` : "",
      source ? `Source: ${this._escape(source)}` : ""
    ].filter(Boolean)

    const chips = participants.slice(0, 10).map((row) => {
      const role = String(row.role || "unknown")
      const roleClass = role === "primary_user" ? "owner" : "person"
      const label = row.label || (row.person_id ? `person_${row.person_id}` : "unknown")
      const recurring = row.recurring_face === true || Number(row.appearances || 0) > 1
      const relationship = String(row.relationship || "")
      const personPath = String(row.person_path || "")
      const realPersonStatus = String(row.real_person_status || "")
      const confidence = Number(row.identity_confidence)
      const detectorConfidence = Number(row.detector_confidence)
      const details = [
        recurring ? "recurring" : "",
        Number.isFinite(detectorConfidence) ? `detector ${this._escape(String(Math.round(detectorConfidence * 100)))}%` : "",
        Number(row.appearances || 0) > 0 ? `seen ${this._escape(String(row.appearances))}x` : "",
        relationship ? this._escape(relationship) : "",
        realPersonStatus ? this._escape(realPersonStatus.replaceAll("_", " ")) : "",
        Number.isFinite(confidence) ? `confidence ${this._escape(String(Math.round(confidence * 100)))}%` : ""
      ].filter(Boolean).join(" | ")
      const body = `${this._escape(String(label))}${details ? ` <small>${details}</small>` : ""}`
      if (personPath) {
        return `<a class="pill face-pill ${roleClass} face-pill-link" href="${this._escape(personPath)}" data-turbo-frame="_top">${body}</a>`
      }
      return `<span class="pill face-pill ${roleClass}">${body}</span>`
    }).join("")

    const summaryLine = participantSummary ? `<p class="meta">${this._escape(participantSummary)}</p>` : ""
    const noConfidentMatchLine = (totalFaces > 0 && participants.length === 0)
      ? `<p class="meta">No confident person matches yet${Number.isFinite(minMatchConfidence) && minMatchConfidence > 0 ? ` (requires >= ${this._escape(String(Math.round(minMatchConfidence * 100)))}% confidence)` : ""}.</p>`
      : ""
    const chipsLine = chips ? `<div class="post-face-chip-row">${chips}</div>` : ""
    return `<p class="meta">${lines.join(" | ")}</p>${noConfidentMatchLine}${summaryLine}${chipsLine}`
  }

  async forwardSuggestion(event) {
    const button = event.target.closest("button[data-forward-comment]")
    if (!button || !this.suggestionsTarget.contains(button)) return

    event.preventDefault()
    const comment = button.dataset.forwardComment || ""
    if (!comment || !this.forwardUrl) return

    button.disabled = true
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content || ""
    const body = new URLSearchParams({ comment })

    try {
      const response = await fetch(this.forwardUrl, {
        method: "POST",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-CSRF-Token": csrf
        },
        body
      })

      if (!response.ok) {
        throw new Error(`Failed to queue comment (${response.status})`)
      }

      const text = await response.text()
      if (window.Turbo && typeof window.Turbo.renderStreamMessage === "function") {
        window.Turbo.renderStreamMessage(text)
      }
    } catch (error) {
      window.__profilePostModalLastError = error?.message || "Unable to queue comment forward action"
    } finally {
      button.disabled = false
    }
  }

  _renderMedia(data) {
    const mediaUrl = String(data.imageUrl || data.mediaUrl || "")
    const contentType = String(data.mediaContentType || "").toLowerCase()
    const previewImageUrl = String(data.mediaPreviewImageUrl || "")
    const staticVideo = this.toBoolean(data.videoStaticFrameOnly)
    const mediaPath = mediaUrl.split("?")[0].toLowerCase()
    const isVideo = this.toBoolean(data.isVideo) ||
      contentType.startsWith("video/") ||
      mediaPath.endsWith(".mp4") ||
      mediaPath.endsWith(".mov") ||
      mediaPath.endsWith(".webm") ||
      mediaPath.endsWith(".m3u8")

    if (!mediaUrl) {
      this.clearMediaVideo()
      this.imageTarget.removeAttribute("src")
      this.imageTarget.classList.add("d-none")
      return
    }

    if (isVideo && this.hasVideoTarget && this.hasVideoShellTarget) {
      this.imageTarget.removeAttribute("src")
      this.imageTarget.classList.add("d-none")
      this.videoShellTarget.classList.remove("d-none")
      this.videoTarget.dataset.videoSource = mediaUrl
      this.videoTarget.dataset.videoContentType = contentType
      this.videoTarget.dataset.videoPosterUrl = previewImageUrl
      this.videoTarget.dataset.videoStatic = staticVideo ? "true" : "false"
      this.videoTarget.dispatchEvent(
        new CustomEvent("video-player:load", {
          detail: { src: mediaUrl, contentType, posterUrl: previewImageUrl, staticVideo, autoplay: false, immediate: false, preload: "none" },
        }),
      )
      return
    }

    this.clearMediaVideo()
    this.imageTarget.src = mediaUrl
    this.imageTarget.classList.remove("d-none")
  }

  clearMediaVideo() {
    if (this.hasVideoTarget) this.videoTarget.dispatchEvent(new CustomEvent("video-player:clear"))
    if (this.hasVideoShellTarget) this.videoShellTarget.classList.add("d-none")
  }

  toBoolean(raw) {
    if (typeof raw === "boolean") return raw
    const value = String(raw || "").trim().toLowerCase()
    return ["1", "true", "yes", "on"].includes(value)
  }

  _escape(s) {
    return String(s)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }
}
