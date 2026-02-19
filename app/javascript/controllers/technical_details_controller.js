import { Controller } from "@hotwired/stimulus"
import { notifyApp } from "../lib/notifications"

export default class extends Controller {
  static targets = ["modal", "loading", "error", "details"]
  static values = { eventId: Number, accountId: Number }

  connect() {
    this.modalVisible = false
    this.lastTechnicalPayload = ""
    this.boundEscapeHandler = (event) => {
      if (event.key === "Escape" && this.modalVisible) this.hideModal()
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundEscapeHandler)
  }

  async showTechnicalDetails(event) {
    event.preventDefault()

    const eventId = event.currentTarget?.dataset?.eventId || this.eventIdValue
    if (!eventId) return

    this.eventIdValue = Number(eventId)
    this.showModal()
    this.showLoading()
    await this.loadTechnicalDetails(String(eventId))
  }

  handleBackdropClick(event) {
    if (event.target === this.modalTarget) this.hideModal()
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  hideModal(event = null) {
    event?.preventDefault()
    if (!this.hasModalTarget) return

    this.modalTarget.classList.add("hidden")
    this.modalVisible = false
    document.body.style.overflow = document.querySelector(".story-modal-overlay") ? "hidden" : ""
    document.removeEventListener("keydown", this.boundEscapeHandler)
  }

  async copyTechnicalData(event) {
    event.preventDefault()
    if (!this.lastTechnicalPayload) return

    try {
      await navigator.clipboard.writeText(this.lastTechnicalPayload)
      notifyApp("Technical data copied to clipboard.", "notice")
    } catch (_) {
      notifyApp("Clipboard copy was blocked by the browser.", "error")
    }
  }

  showModal() {
    if (!this.hasModalTarget) return
    this.modalVisible = true
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", this.boundEscapeHandler)
  }

  async loadTechnicalDetails(eventId) {
    try {
      const response = await fetch(`/instagram_accounts/${this.accountIdValue}/technical_details?event_id=${encodeURIComponent(eventId)}`, {
        headers: { Accept: "application/json" },
      })

      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(payload.error || `Request failed (${response.status})`)
      }

      this.displayTechnicalDetails(payload)
    } catch (error) {
      this.showError(error.message)
    }
  }

  showLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = false
    if (this.hasErrorTarget) {
      this.errorTarget.hidden = true
      this.errorTarget.innerHTML = ""
    }
    if (this.hasDetailsTarget) {
      this.detailsTarget.hidden = true
      this.detailsTarget.innerHTML = ""
    }
  }

  showError(errorMessage) {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = true
    if (this.hasDetailsTarget) this.detailsTarget.hidden = true

    if (this.hasErrorTarget) {
      this.errorTarget.hidden = false
      this.errorTarget.innerHTML = `
        <div class="error-message">
          <h3>Error Loading Technical Details</h3>
          <p>${this.esc(errorMessage)}</p>
          <button class="btn secondary" data-action="click->technical-details#hideModal">Close</button>
        </div>
      `
    }
  }

  displayTechnicalDetails(data) {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = true
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    if (!this.hasDetailsTarget) return

    const details = data.technical_details || {}
    this.lastTechnicalPayload = JSON.stringify(details, null, 2)

    this.detailsTarget.hidden = false
    this.detailsTarget.innerHTML = `
      <div class="technical-details-container">
        <div class="technical-details-header">
          <h3>Technical Details for Event #${this.esc(data.event_id)}</h3>
          <div class="status-indicator ${data.has_llm_comment ? "success" : "pending"}">
            ${data.has_llm_comment ? "AI comment generated" : "No AI comment yet"}
          </div>
        </div>

        ${data.has_llm_comment ? this.displayGeneratedCommentInfo(data) : ""}

        <div class="technical-sections">
          ${this.displaySection("Story Timeline", data.timeline || {})}
          ${this.displaySection("Media Information", details.media_info || {})}
          ${this.displaySection("Local Story Intelligence", details.local_story_intelligence || {})}
          ${this.displaySection("Analysis", details.analysis || {})}
          ${this.displaySection("Profile Analysis", details.profile_analysis || {})}
          ${this.displaySection("Prompt Engineering", details.prompt_engineering || {})}
        </div>

        <div class="technical-details-actions">
          <button class="btn secondary" data-action="click->technical-details#hideModal">Close</button>
          <button class="btn primary" data-action="click->technical-details#copyTechnicalData">Copy Technical Data</button>
        </div>
      </div>
    `
  }

  displayGeneratedCommentInfo(data) {
    return `
      <div class="generated-comment-info">
        <h4>Generated Comment</h4>
        <div class="comment-display">
          <p class="generated-comment">${this.esc(data.llm_comment || "")}</p>
          <div class="comment-meta">
            <span class="meta">Generated: ${this.esc(this.formatDate(data.generated_at))}</span>
            <span class="meta">Model: ${this.esc(data.model || "-")}</span>
            <span class="meta">Provider: ${this.esc(data.provider || "-")}</span>
            <span class="meta">Status: ${this.esc(data.status || "-")}</span>
            <span class="meta">Relevance: ${this.esc(data.relevance_score ?? "-")}</span>
            <span class="meta">Pipeline: local vision + OCR + local LLM</span>
          </div>
        </div>
      </div>
    `
  }

  displaySection(title, data) {
    return `
      <div class="technical-section">
        <h4>${this.esc(title)}</h4>
        <pre class="json-display">${this.esc(JSON.stringify(data || {}, null, 2))}</pre>
      </div>
    `
  }

  formatDate(value) {
    if (!value) return "-"
    const date = new Date(value)
    return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString()
  }

  esc(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }
}
