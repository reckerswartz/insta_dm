import { Controller } from "@hotwired/stimulus"

const MAX_JSON_PAYLOAD_BYTES = 120000
const MAX_RENDERED_ITEMS = 24

export default class extends Controller {
  static targets = ["dialog", "title", "image", "caption", "stats", "comments", "meta", "generation", "download", "permalink", "suggestions", "faces"]

  connect() {
    this.forwardUrl = ""
    this.renderToken = 0
    this.pendingRenderId = null
    this.forwardClickHandler = (event) => this.forwardSuggestion(event)
    this.dialogCloseHandler = () => this._syncGlobalLocks()
    this.dialogCancelHandler = () => this._syncGlobalLocks()
    if (this.hasSuggestionsTarget) this.suggestionsTarget.addEventListener("click", this.forwardClickHandler)
    if (this.hasDialogTarget) {
      this.dialogTarget.addEventListener("close", this.dialogCloseHandler)
      this.dialogTarget.addEventListener("cancel", this.dialogCancelHandler)
      // Defensive reset for stale inline states from interrupted renders/navigation.
      this.dialogTarget.style.removeProperty("display")
    }
  }

  disconnect() {
    if (this.pendingRenderId) window.cancelAnimationFrame(this.pendingRenderId)
    this.pendingRenderId = null
    if (this.hasSuggestionsTarget) this.suggestionsTarget.removeEventListener("click", this.forwardClickHandler)
    if (this.hasDialogTarget) {
      this.dialogTarget.removeEventListener("close", this.dialogCloseHandler)
      this.dialogTarget.removeEventListener("cancel", this.dialogCancelHandler)
    }
    this._forceCloseDialog()
    this._syncGlobalLocks()
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
        this._syncGlobalLocks()
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
      this._forceCloseDialog()
      this._syncGlobalLocks()
    }
  }

  close(event) {
    event?.preventDefault?.()
    this.renderToken += 1
    if (this.pendingRenderId) window.cancelAnimationFrame(this.pendingRenderId)
    this.pendingRenderId = null
    this._forceCloseDialog()
    this._syncGlobalLocks()
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

    this.downloadTarget.href = data.downloadUrl || "#"
    this.permalinkTarget.href = data.permalink || "#"

    if (data.imageUrl) {
      this.imageTarget.src = data.imageUrl
      this.imageTarget.classList.remove("media-shell-hidden")
    } else {
      this.imageTarget.removeAttribute("src")
      this.imageTarget.classList.add("media-shell-hidden")
    }
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

      const comments = this._safeJson(data.commentsJson).slice(0, MAX_RENDERED_ITEMS)
      const suggestions = this._safeJson(data.suggestionsJson).slice(0, MAX_RENDERED_ITEMS)
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
    if (!this.hasDialogTarget) return false
    const dialog = this.dialogTarget

    try {
      if (!dialog.open) dialog.showModal()
      this._ensureDialogVisible(dialog)
      if (!this._isDialogVisible(dialog)) {
        throw new Error("Dialog opened but remained hidden")
      }
      return true
    } catch (error) {
      window.__profilePostModalLastError = error?.message || "Unable to open post modal"
      this._forceCloseDialog()
      return false
    }
  }

  _ensureDialogVisible(dialog) {
    if (!dialog) return

    // Bootstrap's `.modal` class defaults to `display:none`; force native dialog visibility.
    if (window.getComputedStyle(dialog).display === "none") {
      dialog.style.display = "block"
    }
  }

  _isDialogVisible(dialog) {
    if (!dialog || !dialog.open) return false
    const style = window.getComputedStyle(dialog)
    if (style.display === "none" || style.visibility === "hidden") return false
    const rect = dialog.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0
  }

  _forceCloseDialog() {
    if (!this.hasDialogTarget) return
    const dialog = this.dialogTarget

    try {
      if (dialog.open && typeof dialog.close === "function") {
        dialog.close()
      }
    } catch (_) {
      // Ignore and continue with attribute cleanup.
    } finally {
      dialog.removeAttribute("open")
      dialog.style.removeProperty("display")
    }
  }

  _syncGlobalLocks() {
    const hasStoryOverlay = document.querySelector(".story-modal-overlay")
    const hasTechnicalOverlay = document.querySelector(".technical-details-modal:not(.hidden)")
    document.body.style.overflow = hasStoryOverlay || hasTechnicalOverlay ? "hidden" : ""
  }

  _safeJson(raw) {
    const payload = String(raw || "[]")
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
      return `<li><div>${txt}</div><div class="suggestion-action-row"><button type="button" class="btn small" data-forward-comment="${txt}" data-forward-idx="${i}">Forward Comment</button></div></li>`
    }).join("")}</ul>`
  }

  _faceSummaryHtml(payload) {
    const participants = Array.isArray(payload.participants) ? payload.participants : []
    const totalFaces = Number(payload.face_count || 0)
    const ownerFaces = Number(payload.owner_faces_count || 0)
    const recurringFaces = Number(payload.recurring_faces_count || 0)
    const source = String(payload.detection_source || "")
    const participantSummary = String(payload.participant_summary || "")

    if (totalFaces <= 0 && participants.length === 0) {
      return "<p class='meta'>No detected faces for this post yet.</p>"
    }

    const lines = [
      `Faces: <strong>${this._escape(String(totalFaces))}</strong>`,
      ownerFaces > 0 ? `Owner matches: <strong>${this._escape(String(ownerFaces))}</strong>` : "",
      recurringFaces > 0 ? `Recurring: <strong>${this._escape(String(recurringFaces))}</strong>` : "",
      source ? `Source: ${this._escape(source)}` : ""
    ].filter(Boolean)

    const chips = participants.slice(0, 10).map((row) => {
      const role = String(row.role || "unknown")
      const roleClass = role === "primary_user" ? "owner" : "person"
      const label = row.label || (row.person_id ? `person_${row.person_id}` : "unknown")
      const recurring = row.recurring_face === true || Number(row.appearances || 0) > 1
      const relationship = String(row.relationship || "")
      const details = [
        recurring ? "recurring" : "",
        Number(row.appearances || 0) > 0 ? `seen ${this._escape(String(row.appearances))}x` : "",
        relationship ? this._escape(relationship) : ""
      ].filter(Boolean).join(" | ")

      return `<span class="pill face-pill ${roleClass}">${this._escape(String(label))}${details ? ` <small>${details}</small>` : ""}</span>`
    }).join("")

    const summaryLine = participantSummary ? `<p class="meta">${this._escape(participantSummary)}</p>` : ""
    const chipsLine = chips ? `<div class="post-face-chip-row">${chips}</div>` : ""
    return `<p class="meta">${lines.join(" | ")}</p>${summaryLine}${chipsLine}`
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

  _escape(s) {
    return String(s)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
