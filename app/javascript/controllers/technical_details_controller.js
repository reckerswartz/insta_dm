import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "content", "loading", "error"]
  static values = { eventId: Number, accountId: Number }

  connect() {
    this.modalVisible = false
  }

  async showTechnicalDetails(event) {
    const button = event.target
    const eventId = button.dataset.eventId || this.eventIdValue
    
    if (!eventId) {
      console.error("No event ID found for technical details")
      return
    }

    // Find the global modal
    const modal = document.querySelector(".technical-details-modal")
    if (!modal) {
      console.error("Technical details modal not found")
      return
    }

    // Store the event ID for later use
    this.eventIdValue = eventId
    
    this.showModal(modal)
    await this.loadTechnicalDetails(eventId)
  }

  hideModal() {
    const modal = document.querySelector(".technical-details-modal")
    if (modal) {
      modal.classList.add("hidden")
    }
    this.modalVisible = false
    document.body.style.overflow = ""
  }

  showModal(modal) {
    this.modalVisible = true
    modal.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    
    // Add escape key listener
    document.addEventListener("keydown", this.handleEscapeKey.bind(this))
  }

  async loadTechnicalDetails(eventId) {
    const modal = document.querySelector(".technical-details-modal")
    const loadingTarget = modal.querySelector("[data-technical-details-target='loading']")
    const contentTarget = modal.querySelector("[data-technical-details-target='content']")
    const errorTarget = modal.querySelector("[data-technical-details-target='error']")
    
    this.showLoading(loadingTarget, contentTarget, errorTarget)
    
    try {
      const response = await fetch(`/instagram_accounts/${this.accountIdValue}/technical_details?event_id=${eventId}`, {
        headers: {
          "Accept": "application/json"
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`)
      }

      const data = await response.json()
      this.displayTechnicalDetails(data, contentTarget, errorTarget)
      
    } catch (error) {
      console.error("Error loading technical details:", error)
      this.showError(error.message, contentTarget, errorTarget)
    }
  }

  showLoading(loadingTarget, contentTarget, errorTarget) {
    loadingTarget.classList.remove("hidden")
    contentTarget.classList.add("hidden")
    errorTarget.classList.add("hidden")
  }

  showError(errorMessage, contentTarget, errorTarget) {
    const modal = document.querySelector(".technical-details-modal")
    const loadingTarget = modal.querySelector("[data-technical-details-target='loading']")
    
    loadingTarget.classList.add("hidden")
    contentTarget.classList.add("hidden")
    errorTarget.classList.remove("hidden")
    
    errorTarget.innerHTML = `
      <div class="error-message">
        <h3>Error Loading Technical Details</h3>
        <p>${this.esc(errorMessage)}</p>
        <button class="btn secondary" data-action="click->technical-details#hideModal">Close</button>
      </div>
    `
  }

  displayTechnicalDetails(data, contentTarget, errorTarget) {
    const modal = document.querySelector(".technical-details-modal")
    const loadingTarget = modal.querySelector("[data-technical-details-target='loading']")
    
    loadingTarget.classList.add("hidden")
    contentTarget.classList.remove("hidden")
    errorTarget.classList.add("hidden")
    
    const details = data.technical_details || {}
    
    contentTarget.innerHTML = `
      <div class="technical-details-container">
        <div class="technical-details-header">
          <h3>Technical Details for Event #${data.event_id}</h3>
          <div class="status-indicator ${data.has_llm_comment ? 'success' : 'pending'}">
            ${data.has_llm_comment ? '✓ AI Comment Generated' : '○ No AI Comment'}
          </div>
        </div>

        ${data.has_llm_comment ? this.displayGeneratedCommentInfo(data) : ''}

        <div class="technical-sections">
          ${this.displaySection('Media Information', details.media_info || {})}
          ${this.displaySection('Profile Analysis', details.profile_analysis || {})}
          ${this.displaySection('Vision Analysis', details.vision_analysis || {})}
          ${this.displaySection('OCR Results', details.ocr_results || {})}
          ${this.displaySection('Account History', details.account_history || {})}
          ${this.displaySection('Prompt Engineering', details.prompt_engineering || {})}
        </div>

        <div class="technical-details-actions">
          <button class="btn secondary" data-action="click->technical-details#hideModal">Close</button>
          <button class="btn primary" onclick="navigator.clipboard.writeText(JSON.stringify(${JSON.stringify(details)}, null, 2))">
            📋 Copy Technical Data
          </button>
        </div>
      </div>
    `
  }

  displayGeneratedCommentInfo(data) {
    return `
      <div class="generated-comment-info">
        <h4>Generated Comment</h4>
        <div class="comment-display">
          <p class="generated-comment">${this.esc(data.llm_comment)}</p>
          <div class="comment-meta">
            <span class="meta">Generated: ${data.generated_at ? new Date(data.generated_at).toLocaleString() : 'Unknown'}</span>
            <span class="meta">Model: ${this.esc(data.model || 'Unknown')}</span>
            <span class="meta">Provider: ${this.esc(data.provider || 'Unknown')}</span>
          </div>
        </div>
      </div>
    `
  }

  displaySection(title, data) {
    return `
      <div class="technical-section">
        <h4>${this.esc(title)}</h4>
        <div class="section-content">
          ${this.formatDataAsJson(data)}
        </div>
      </div>
    `
  }

  formatDataAsJson(data) {
    const formatted = JSON.stringify(data, null, 2)
      .replace(/"/g, '&quot;')
      .replace(/\\n/g, '<br>')
      .replace(/\\t/g, '&nbsp;&nbsp;&nbsp;&nbsp;')
    
    return `<pre class="json-display">${formatted}</pre>`
  }

  handleEscapeKey(event) {
    if (event.key === 'Escape' && this.modalVisible) {
      this.hideModal()
    }
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
