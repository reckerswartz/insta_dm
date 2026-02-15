import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["gallery", "loader", "empty", "scroll", "dateInput", "refreshSignal"]
  static values = { url: String }

  connect() {
    this.page = 1
    this.hasMore = true
    this.loading = false
    this.totalLoaded = 0
    this.perPage = 24
    this.pendingRefresh = false
    this.refreshTimer = null
    this.installRefreshSignalObserver()
    this.refresh()
  }

  get application() {
    return window.Stimulus || this.constructor.application
  }

  disconnect() {
    if (this.refreshObserver) this.refreshObserver.disconnect()
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
  }

  refresh() {
    this.page = 1
    this.hasMore = true
    this.totalLoaded = 0
    this.galleryTarget.innerHTML = ""
    this.emptyTarget.hidden = true
    this.loadNextPage()
  }

  changeDate() {
    this.refresh()
  }

  onScroll() {
    if (!this.hasMore || this.loading) return
    if (!this.nearBottom()) return
    this.loadNextPage()
  }

  nearBottom() {
    const el = this.scrollTarget
    return (el.scrollTop + el.clientHeight) >= (el.scrollHeight - 300)
  }

  async loadNextPage() {
    if (this.loading || !this.hasMore) return
    this.loading = true
    this.loaderTarget.hidden = false

    try {
      const url = this.buildUrl()
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`Request failed (${response.status})`)

      const payload = await response.json()
      const items = Array.isArray(payload.items) ? payload.items : []

      if (this.page === 1 && items.length === 0) {
        this.emptyTarget.hidden = false
      }

      items.forEach((item) => {
        this.galleryTarget.insertAdjacentHTML("beforeend", this.cardHtml(item))
      })
      
      // Let Stimulus discover the new controllers
      if (this.application) {
        this.application.controllers.start()
      }
      this.totalLoaded += items.length

      this.hasMore = Boolean(payload.has_more)
      this.page += 1
      if (this.pendingRefresh) {
        this.pendingRefresh = false
        this.scheduleRefresh()
      }
    } catch (error) {
      this.loaderTarget.textContent = `Unable to load media archive: ${error.message}`
      this.hasMore = false
    } finally {
      this.loading = false
      if (this.hasMore) {
        this.loaderTarget.textContent = "Scroll for more story media…"
      } else if (this.totalLoaded > 0) {
        this.loaderTarget.textContent = "You reached the end of the archive."
      }
    }
  }

  installRefreshSignalObserver() {
    if (!this.hasRefreshSignalTarget) return
    this.refreshObserver = new MutationObserver(() => {
      if (this.loading) {
        this.pendingRefresh = true
        return
      }
      this.scheduleRefresh()
    })
    this.refreshObserver.observe(this.refreshSignalTarget, {
      childList: true,
      subtree: true,
      characterData: true
    })
  }

  scheduleRefresh() {
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.refresh(), 150)
  }

  buildUrl() {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("page", String(this.page))
    url.searchParams.set("per_page", String(this.perPage))
    const on = this.dateInputTarget.value
    if (on) url.searchParams.set("on", on)
    return url.toString()
  }

  cardHtml(item) {
    const contentType = String(item.media_content_type || "")
    const isVideo = contentType.startsWith("video/")

    const mediaHtml = isVideo
      ? `<video controls preload="none" src="${this.esc(item.media_url)}"></video>`
      : `<img loading="lazy" src="${this.esc(item.media_url)}" alt="Story media preview" />`

    const bytes = Number(item.media_bytes || 0)
    const sizeKb = bytes > 0 ? `${(bytes / 1024).toFixed(1)} KB` : "-"
    const dimensions = item.media_width && item.media_height ? `${item.media_width}x${item.media_height}` : "-"
    const occurred = item.occurred_at ? new Date(item.occurred_at).toLocaleString() : "-"

    const profileHtml = item.app_profile_url
      ? `<a href="${this.esc(item.app_profile_url)}">@${this.esc(item.profile_username)}</a>`
      : `<code>@${this.esc(item.profile_username || "-")}</code>`
    const igProfile = item.instagram_profile_url
      ? `<a href="${this.esc(item.instagram_profile_url)}" target="_blank" rel="noopener noreferrer">IG</a>`
      : ""
    const storyLink = item.story_url
      ? `<a href="${this.esc(item.story_url)}" target="_blank" rel="noopener noreferrer">Story Link</a>`
      : ""
    const replyCommentBlock = item.reply_comment
      ? `<p class="story-reply-comment" title="Exact reply sent to this story"><strong>Reply sent:</strong> ${this.esc(item.reply_comment)}</p>`
      : ""
    const skippedBlock = item.skipped && item.skip_reason
      ? `<p class="meta story-skipped-badge">Skipped (not analyzed): ${this.esc(item.skip_reason)}</p>`
      : ""

    // LLM Comment section
    const llmCommentSection = this.buildLlmCommentSection(item)
    const accountId = this.getAccount_id()
    console.log("Creating story card with account ID:", accountId)

    return `
      <article class="story-media-card" data-event-id="${this.esc(item.id.toString())}" data-controller="llm-comment technical-details" data-llm-comment-account-id-value="${this.esc(accountId || '')}" data-technical-details-account-id-value="${this.esc(accountId || '')}">
        <div class="story-media-preview">${mediaHtml}</div>
        <div class="story-media-meta">
          <p><strong>${profileHtml}</strong> ${igProfile}</p>
          <p class="meta">${this.esc(occurred)}</p>
          <p class="meta">Type: ${this.esc(contentType || "-")} | Size: ${this.esc(sizeKb)} | Dim: ${this.esc(dimensions)}</p>
          ${skippedBlock}
          ${replyCommentBlock}
          ${llmCommentSection}
          <div class="actions-row">
            <a class="btn small secondary" href="${this.esc(item.media_download_url)}" target="_blank" rel="noreferrer">Download</a>
            ${storyLink ? `<span class="meta">${storyLink}</span>` : ""}
            <button class="btn small primary story-detail-btn" data-action="click->story-media-archive#openStoryModal">Details</button>
            ${item.has_llm_comment ? `
              <button class="btn small secondary technical-details-btn" 
                      data-action="click->technical-details#showTechnicalDetails" 
                      data-event-id="${this.esc(item.id.toString())}">
                🔧 Technical Details
              </button>
            ` : ''}
          </div>
        </div>
      </article>
    `
  }

  buildLlmCommentSection(item) {
    if (item.has_llm_comment && item.llm_generated_comment) {
      const generatedAt = item.llm_comment_generated_at 
        ? new Date(item.llm_comment_generated_at).toLocaleString() 
        : "Unknown"
      
      return `
        <div class="llm-comment-section">
          <p class="llm-generated-comment" title="AI-generated comment suggestion">
            <strong>AI Suggestion:</strong> ${this.esc(item.llm_generated_comment)}
          </p>
          <p class="meta llm-comment-meta">
            Generated ${this.esc(generatedAt)} 
            ${item.llm_comment_provider ? `via ${this.esc(item.llm_comment_provider)}` : ""}
            ${item.llm_comment_model ? `(${this.esc(item.llm_comment_model)})` : ""}
          </p>
        </div>
      `
    } else {
      console.log("Creating generate comment button for event:", item.id)
      const accountId = this.getAccount_id()
      return `
        <div class="llm-comment-section">
          <button class="btn small secondary generate-comment-btn" 
                  data-action="click->llm-comment#generateComment"
                  data-event-id="${this.esc(item.id.toString())}"
                  onclick="window.generateCommentFallback(${this.esc(item.id.toString())}, ${this.esc(accountId || 'null')})">
            Generate Comment Locally
          </button>
        </div>
      `
    }
  }

  openStoryModal(event) {
    const button = event.target
    const storyCard = button.closest(".story-media-card")
    const eventId = storyCard?.dataset.eventId
    
    if (!eventId) return

    // Create modal overlay
    const modal = document.createElement("div")
    modal.className = "story-modal-overlay"
    modal.innerHTML = `
      <div class="story-modal">
        <div class="story-modal-header">
          <h3>Story Details</h3>
          <button class="modal-close" data-action="click->story-media-archive#closeModal">&times;</button>
        </div>
        <div class="story-modal-content">
          <p>Loading story details...</p>
        </div>
      </div>
    `
    
    document.body.appendChild(modal)
    
    // Load story details into modal
    this.loadStoryDetails(eventId, modal)
  }

  async loadStoryDetails(eventId, modal) {
    try {
      // Find the story card data from the current page
      const storyCard = document.querySelector(`[data-event-id="${eventId}"]`)
      if (!storyCard) return

      // Extract data from the card
      const mediaElement = storyCard.querySelector("img, video")
      const profileLink = storyCard.querySelector("a[href*='instagram_profiles']")
      const llmComment = storyCard.querySelector(".llm-generated-comment")
      
      const content = `
        <div class="story-detail-view">
          <div class="story-detail-media">
            ${mediaElement ? mediaElement.outerHTML : ""}
          </div>
          <div class="story-detail-info">
            ${profileLink ? `<p><strong>Profile:</strong> ${profileLink.outerHTML}</p>` : ""}
            ${llmComment ? `<div class="llm-comment-detail">${llmComment.outerHTML}</div>` : ""}
            <div class="story-detail-actions">
              <button class="btn secondary" data-action="click->story-media-archive#closeModal">Close</button>
            </div>
          </div>
        </div>
      `
      
      modal.querySelector(".story-modal-content").innerHTML = content
      
    } catch (error) {
      console.error("Error loading story details:", error)
      modal.querySelector(".story-modal-content").innerHTML = 
        `<p class="error">Failed to load story details: ${error.message}</p>`
    }
  }

  closeModal(event) {
    const modal = event.target.closest(".story-modal-overlay")
    if (modal) {
      modal.remove()
    }
  }

  getAccount_id() {
    // Extract account ID from current URL path
    const pathParts = window.location.pathname.split('/')
    const accountIndex = pathParts.indexOf('instagram_accounts')
    if (accountIndex !== -1 && pathParts[accountIndex + 1]) {
      const accountId = pathParts[accountIndex + 1]
      console.log("Extracted account ID:", accountId)
      return accountId
    }
    console.error("Could not extract account ID from path:", window.location.pathname)
    return null
  }

  getCsrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }

  showNotification(message, type = "notice") {
    // Create notification element
    const notification = document.createElement("div")
    notification.className = `notification ${type}`
    notification.textContent = message
    
    // Add to notifications container
    const container = document.getElementById("notifications")
    if (container) {
      container.appendChild(notification)
      
      // Auto-remove after 5 seconds
      setTimeout(() => {
        notification.remove()
      }, 5000)
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
