import { Controller } from "@hotwired/stimulus"

const INTERACTIVE_SELECTOR = "a,button,input,textarea,select,label,[role='button'],video,.plyr"

export default class extends Controller {
  static targets = ["gallery", "loader", "empty", "scroll", "dateInput", "refreshSignal", "loadButton"]
  static values = { url: String, accountId: Number, autoload: { type: Boolean, default: false } }

  connect() {
    this.page = 1
    this.hasMore = true
    this.loading = false
    this.totalLoaded = 0
    this.perPage = 12
    this.pendingRefresh = false
    this.refreshTimer = null
    this.initialRefreshTimer = null
    this.lastRefreshAt = 0
    this.minRefreshIntervalMs = 1200
    this.lastRefreshSignalValue = ""
    this.itemsById = new Map()
    this.modalEl = null
    this.bootstrapped = false
    this.boundHandleModalKeydown = this.handleModalKeydown.bind(this)
    this.lastRefreshSignalValue = this.readRefreshSignalValue()
    this.installRefreshSignalObserver()
    this.installScrollEnhancements()

    this.loaderTarget.hidden = false
    this.loaderTarget.textContent = "Archive idle. Click Load Archive to fetch media."

    if (this.autoloadValue) {
      this.bootstrap()
    }
  }

  disconnect() {
    this.closeStoryModal()
    if (this.refreshObserver) this.refreshObserver.disconnect()
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    if (this.initialRefreshTimer) clearTimeout(this.initialRefreshTimer)
    if (this.initialRefreshIdleId && "cancelIdleCallback" in window) window.cancelIdleCallback(this.initialRefreshIdleId)
    this.cleanupScrollEnhancements?.()
  }

  refresh(event) {
    event?.preventDefault()
    this.bootstrapped = true
    if (this.hasLoadButtonTarget) {
      this.loadButtonTarget.disabled = true
      this.loadButtonTarget.textContent = "Archive Loaded"
    }
    this.lastRefreshAt = Date.now()
    this.page = 1
    this.hasMore = true
    this.totalLoaded = 0
    this.itemsById.clear()
    this.galleryTarget.innerHTML = ""
    this.emptyTarget.hidden = true
    this.loaderTarget.hidden = false
    this.closeStoryModal()
    this.loadNextPage()
  }

  bootstrap(event) {
    event?.preventDefault()
    if (this.bootstrapped) return

    this.bootstrapped = true
    if (this.hasLoadButtonTarget) {
      this.loadButtonTarget.disabled = true
      this.loadButtonTarget.textContent = "Archive Loaded"
    }
    this.scheduleInitialRefresh()
  }

  changeDate() {
    if (!this.bootstrapped) {
      this.bootstrap()
      return
    }
    this.refresh()
  }

  onScroll() {
    if (!this.bootstrapped) return
    if (!this.hasMore || this.loading) return
    if (!this.nearBottom()) return
    this.loadNextPage()
  }

  nearBottom() {
    const el = this.scrollTarget
    return (el.scrollTop + el.clientHeight) >= (el.scrollHeight - 320)
  }

  async loadNextPage() {
    if (this.loading || !this.hasMore) return
    this.loading = true
    this.loaderTarget.hidden = false

    try {
      const response = await fetch(this.buildUrl(), { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`Request failed (${response.status})`)

      const payload = await response.json()
      const items = Array.isArray(payload.items) ? payload.items : []

      if (this.page === 1 && items.length === 0) {
        this.emptyTarget.hidden = false
      }

      const prepared = items.filter((item) => item && typeof item.id !== "undefined" && item.id !== null)
      prepared.forEach((item) => {
        this.itemsById.set(String(item.id), item)
      })
      await this.appendPreparedItems(prepared)
      this.totalLoaded += prepared.length

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
        this.loaderTarget.textContent = "Scroll for more story media..."
      } else if (this.totalLoaded > 0) {
        this.loaderTarget.textContent = "You reached the end of the archive."
      } else {
        this.loaderTarget.hidden = true
      }
    }
  }

  async appendPreparedItems(items) {
    if (!Array.isArray(items) || items.length === 0) return

    const chunkSize = 6
    for (let start = 0; start < items.length; start += chunkSize) {
      const html = items
        .slice(start, start + chunkSize)
        .map((item) => this.cardHtml(item))
        .join("")

      if (html) this.galleryTarget.insertAdjacentHTML("beforeend", html)
      if (start + chunkSize < items.length) await this.yieldToBrowser()
    }
  }

  yieldToBrowser() {
    return new Promise((resolve) => {
      if ("requestAnimationFrame" in window) {
        window.requestAnimationFrame(() => resolve())
        return
      }
      setTimeout(resolve, 0)
    })
  }

  installRefreshSignalObserver() {
    if (!this.hasRefreshSignalTarget) return
    this.refreshObserver = new MutationObserver(() => {
      const nextValue = this.readRefreshSignalValue()
      if (nextValue === this.lastRefreshSignalValue) return
      this.lastRefreshSignalValue = nextValue
      if (!this.bootstrapped) return

      if (this.loading) {
        this.pendingRefresh = true
        return
      }
      this.scheduleRefresh()
    })
    this.refreshObserver.observe(this.refreshSignalTarget, {
      childList: true,
      subtree: true,
      characterData: true,
    })
  }

  scheduleInitialRefresh() {
    const run = () => this.refresh()
    if ("requestIdleCallback" in window) {
      this.initialRefreshIdleId = window.requestIdleCallback(run, { timeout: 1200 })
      return
    }

    this.initialRefreshTimer = setTimeout(run, 180)
  }

  scheduleRefresh() {
    if (this.refreshTimer) clearTimeout(this.refreshTimer)

    const elapsed = Date.now() - this.lastRefreshAt
    const delay = Math.max(250, this.minRefreshIntervalMs - Math.max(elapsed, 0))
    this.refreshTimer = setTimeout(() => this.refresh(), delay)
  }

  readRefreshSignalValue() {
    if (!this.hasRefreshSignalTarget) return ""
    return this.refreshSignalTarget.innerHTML?.trim() || ""
  }

  buildUrl() {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("page", String(this.page))
    url.searchParams.set("per_page", String(this.perPage))
    const on = this.hasDateInputTarget ? this.dateInputTarget.value : ""
    if (on) url.searchParams.set("on", on)
    return url.toString()
  }

  cardHtml(item) {
    const eventId = String(item.id)
    const contentType = String(item.media_content_type || "")
    const isVideo = contentType.startsWith("video/")
    const videoStatic = this.videoIsStatic(item)
    const previewHtml = isVideo ?
      `
        <div class="story-media-preview story-video-player-shell ${videoStatic ? "story-video-static-preview" : ""}">
          ${this.videoElementHtml({
            src: item.media_url,
            contentType,
            posterUrl: this.videoPosterUrl(item),
            staticVideo: videoStatic,
            preload: "none",
            controls: true,
            muted: false,
            autoplay: false,
            deferSourceLoad: true,
            deferUntilVisible: true,
          })}
        </div>
      ` :
      `
        <button
          type="button"
          class="story-media-preview story-preview-button"
          data-event-id="${this.esc(eventId)}"
          data-action="click->story-media-archive#openStoryModal"
        >
          <img loading="lazy" src="${this.esc(item.media_url)}" alt="Story media preview" />
        </button>
      `

    const bytes = Number(item.media_bytes || 0)
    const sizeText = bytes > 0 ? `${(bytes / 1024).toFixed(1)} KB` : "-"
    const dimensions = (item.media_width && item.media_height) ? `${item.media_width}x${item.media_height}` : "-"
    const profileName = item.profile_display_name || item.profile_username || "unknown"
    const profileHandle = item.profile_username ? `@${item.profile_username}` : "@unknown"
    const profileHtml = item.app_profile_url ?
      `<a href="${this.esc(item.app_profile_url)}">${this.esc(profileHandle)}</a>` :
      `<code>${this.esc(profileHandle)}</code>`
    const avatarUrl = item.profile_avatar_url || ""
    const igStoryLink = item.story_url || item.instagram_profile_url || ""
    const igIconSvg = `
      <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d="M7 2h10a5 5 0 0 1 5 5v10a5 5 0 0 1-5 5H7a5 5 0 0 1-5-5V7a5 5 0 0 1 5-5Zm0 2a3 3 0 0 0-3 3v10a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3V7a3 3 0 0 0-3-3H7Zm5 3.25A4.75 4.75 0 1 1 7.25 12 4.76 4.76 0 0 1 12 7.25Zm0 2A2.75 2.75 0 1 0 14.75 12 2.75 2.75 0 0 0 12 9.25ZM17.5 6.5a1.25 1.25 0 1 1-1.25 1.25A1.25 1.25 0 0 1 17.5 6.5Z"/>
      </svg>
    `
    const igIcon = igStoryLink ?
      `<a class="story-open-instagram" href="${this.esc(igStoryLink)}" target="_blank" rel="noopener noreferrer" aria-label="Open original story on Instagram">${igIconSvg}</a>` :
      `<span class="story-open-instagram muted" aria-hidden="true">${igIconSvg}</span>`

    const replyCommentBlock = item.reply_comment ?
      `<p class="story-reply-comment"><strong>Reply sent:</strong> ${this.esc(item.reply_comment)}</p>` :
      ""

    const skippedBlock = (item.skipped && item.skip_reason) ?
      `<p class="meta story-skipped-badge">Skipped: ${this.esc(item.skip_reason)}</p>` :
      ""

    return `
      <article class="story-media-card" data-event-id="${this.esc(eventId)}">
        <div class="story-card-banner">
          <div class="story-card-user">
            ${avatarUrl ? `<img class="story-card-avatar" src="${this.esc(avatarUrl)}" alt="${this.esc(profileName)} avatar" loading="lazy" />` : `<span class="story-card-avatar story-card-avatar-placeholder">?</span>`}
            <div class="story-card-user-text">
              <strong>${this.esc(profileName)}</strong>
              <span class="meta">${profileHtml}</span>
            </div>
          </div>
          ${igIcon}
        </div>

        ${previewHtml}

        <div class="story-media-meta">
          <p class="meta">Type: ${this.esc(contentType || "-")} | Size: ${this.esc(sizeText)} | Dim: ${this.esc(dimensions)}</p>
          ${videoStatic ? `<p class="meta">Static visual video detected: image-first preview enabled.</p>` : ""}
          ${skippedBlock}
          ${replyCommentBlock}
          ${this.buildLlmCommentSection(item)}

          <div class="actions-row">
            <a class="btn small secondary" href="${this.esc(item.media_download_url)}" target="_blank" rel="noreferrer">Download</a>
            <button type="button" class="btn small primary" data-event-id="${this.esc(eventId)}" data-action="click->story-media-archive#openStoryModal">View</button>
            <button type="button" class="btn small secondary" data-event-id="${this.esc(eventId)}" data-action="click->technical-details#showTechnicalDetails">Technical Details</button>
          </div>
        </div>
      </article>
    `
  }

  buildLlmCommentSection(item) {
    const status = String(item.llm_comment_status || "").toLowerCase()
    const ownershipLabel = String(item.story_ownership_label || "").trim()
    const ownershipSummary = String(item.story_ownership_summary || "").trim()
    const ownershipConfidence = typeof item.story_ownership_confidence === "number" ? item.story_ownership_confidence.toFixed(2) : ""

    if (item.has_llm_comment && item.llm_generated_comment) {
      const generatedAt = this.formatDate(item.llm_comment_generated_at)
      const suggestionPreview = item.llm_generated_comment_preview || item.llm_generated_comment
      return `
        <div class="llm-comment-section success">
          <p class="llm-generated-comment"><strong>AI Suggestion:</strong> ${this.esc(suggestionPreview)}</p>
          <p class="meta llm-comment-meta">
            Generated ${this.esc(generatedAt)}
            ${item.llm_comment_provider ? ` via ${this.esc(item.llm_comment_provider)}` : ""}
            ${item.llm_comment_model ? ` (${this.esc(item.llm_comment_model)})` : ""}
            ${typeof item.llm_comment_relevance_score === "number" ? ` | relevance ${this.esc(item.llm_comment_relevance_score.toFixed(2))}` : ""}
          </p>
        </div>
      `
    }

    const inFlight = status === "queued" || status === "running"
    const skipped = status === "skipped"
    const skippedLabel = ownershipLabel ? `Skipped (${ownershipLabel.replaceAll("_", " ")})` : "Skipped (no usable verified context)"
    const label = skipped ? skippedLabel : (status === "running" ? "Generating..." : (status === "queued" ? "Queued..." : "Not generated yet"))
    const lastError = item.llm_comment_last_error_preview || item.llm_comment_last_error
    const errorPrefix = skipped ? "Details" : "Last error"
    const error = lastError ? `<p class="meta error-text">${this.esc(errorPrefix)}: ${this.esc(lastError)}</p>` : ""
    const hint = inFlight
      ? "Please wait..."
      : (skipped ? (ownershipSummary || "Try again after verified story context is available.") : "Open View to generate a local comment.")
    const classificationMeta = ownershipLabel ?
      `<p class="meta">Classification: <strong>${this.esc(ownershipLabel.replaceAll("_", " "))}</strong>${ownershipConfidence ? ` (confidence ${this.esc(ownershipConfidence)})` : ""}</p>` :
      ""

    return `
      <div class="llm-comment-section">
        ${classificationMeta}
        <p class="meta">${this.esc(label)}. ${this.esc(hint)}</p>
        ${error}
      </div>
    `
  }

  openStoryModal(event) {
    event.preventDefault()
    const eventId = event.currentTarget?.dataset?.eventId || event.target?.closest("[data-event-id]")?.dataset?.eventId
    if (!eventId) return

    const item = this.itemsById.get(String(eventId))
    if (!item) return

    this.closeStoryModal()

    const modal = document.createElement("div")
    modal.className = "story-modal-overlay"
    modal.innerHTML = this.modalHtml(item)

    modal.addEventListener("click", (clickEvent) => {
      if (clickEvent.target === modal || clickEvent.target.closest("[data-modal-close='story']")) {
        this.closeStoryModal()
      }
    })

    this.element.appendChild(modal)
    this.modalEl = modal
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", this.boundHandleModalKeydown)
  }

  closeModal(event) {
    event?.preventDefault()
    this.closeStoryModal()
  }

  closeStoryModal() {
    if (this.modalEl) {
      this.modalEl.remove()
      this.modalEl = null
    }
    document.removeEventListener("keydown", this.boundHandleModalKeydown)
    document.body.style.overflow = document.querySelector(".technical-details-modal:not(.hidden)") ? "hidden" : ""
  }

  modalHtml(item) {
    const contentType = String(item.media_content_type || "")
    const isVideo = contentType.startsWith("video/")
    const videoStatic = this.videoIsStatic(item)
    const posterUrl = this.videoPosterUrl(item)
    const downloaded = this.formatDate(item.downloaded_at)
    const mediaHtml = isVideo ?
      `
        <div class="story-video-player-shell ${videoStatic ? "story-video-static-preview" : ""}">
          ${this.videoElementHtml({
            src: item.media_url,
            contentType,
            posterUrl: posterUrl,
            staticVideo: videoStatic,
            preload: "none",
            controls: true,
            muted: false,
            autoplay: false,
            deferSourceLoad: true,
            deferUntilVisible: false,
          })}
        </div>
      ` :
      `<img src="${this.esc(item.media_url)}" alt="Story media" />`

    const comment = item.llm_generated_comment ?
      `
        <section class="story-modal-section">
          <h4>AI Suggestion</h4>
          <p class="llm-generated-comment">${this.esc(item.llm_generated_comment)}</p>
        </section>
      ` :
      `
        <section class="story-modal-section">
          <h4>Generate Suggestion</h4>
          <button
            type="button"
            class="btn secondary generate-comment-btn"
            data-event-id="${this.esc(String(item.id))}"
            data-action="click->llm-comment#generateComment"
          >
            Generate Comment Locally
          </button>
        </section>
      `

    return `
      <div class="story-modal" role="dialog" aria-modal="true" aria-label="Story details">
        <div class="story-modal-header">
          <h3>Story Archive Item</h3>
          <button type="button" class="modal-close" data-modal-close="story" aria-label="Close story modal">&times;</button>
        </div>

        <div class="story-modal-content">
          <div class="story-detail-view">
            <div class="story-detail-media">${mediaHtml}</div>
            <div class="story-detail-info">
              <p><strong>Profile:</strong> @${this.esc(item.profile_username || "unknown")}</p>
              <p class="meta"><strong>Downloaded:</strong> ${this.esc(downloaded)}</p>
              <p class="meta"><strong>Type:</strong> ${this.esc(contentType || "-")}</p>
              ${videoStatic ? `<p class="meta"><strong>Playback mode:</strong> Static visual + optional audio/video playback.</p>` : ""}
              ${item.reply_comment ? `<p><strong>Reply sent:</strong> ${this.esc(item.reply_comment)}</p>` : ""}
              ${comment}
              <div class="story-detail-actions">
                <a class="btn secondary" href="${this.esc(item.media_download_url)}" target="_blank" rel="noreferrer">Download</a>
                <button type="button" class="btn secondary" data-event-id="${this.esc(String(item.id))}" data-action="click->technical-details#showTechnicalDetails">Technical Details</button>
                <button type="button" class="btn" data-modal-close="story">Close</button>
              </div>
            </div>
          </div>
        </div>
      </div>
    `
  }

  handleModalKeydown(event) {
    if (event.key === "Escape") this.closeStoryModal()
  }

  videoElementHtml({
    src,
    contentType = "",
    posterUrl,
    staticVideo,
    preload,
    controls,
    muted,
    autoplay,
    deferSourceLoad = false,
    deferUntilVisible = false,
  }) {
    const attrs = [
      `preload="${this.esc(preload || "metadata")}"`,
      controls ? "controls" : "",
      "playsinline",
      muted ? "muted" : "",
      autoplay ? "autoplay" : "",
      "data-controller=\"video-player\"",
      `data-video-player-static-value="${staticVideo ? "true" : "false"}"`,
      `data-video-player-defer-until-visible-value="${deferUntilVisible ? "true" : "false"}"`,
      `data-video-player-preload-value="${this.esc(preload || "none")}"`,
      "data-video-player-load-on-play-value=\"true\"",
      `data-video-content-type="${this.esc(contentType)}"`,
    ].filter(Boolean)

    if (deferSourceLoad) {
      attrs.push(`data-video-source="${this.esc(src || "")}"`)
    } else {
      attrs.push(`src="${this.esc(src || "")}"`)
    }

    if (posterUrl) {
      attrs.push(`poster="${this.esc(posterUrl)}"`)
      attrs.push(`data-video-player-poster-url-value="${this.esc(posterUrl)}"`)
      attrs.push(`data-video-poster-url="${this.esc(posterUrl)}"`)
    }

    attrs.push(`data-video-static="${staticVideo ? "true" : "false"}"`)
    return `<video ${attrs.join(" ")}></video>`
  }

  videoPosterUrl(item) {
    return String(item.media_preview_image_url || item.poster_url || "").trim()
  }

  videoIsStatic(item) {
    const raw = item.video_static_frame_only
    if (typeof raw === "boolean") return raw
    if (typeof raw === "string") return ["1", "true", "yes", "on"].includes(raw.toLowerCase())
    return false
  }

  installScrollEnhancements() {
    if (!this.hasScrollTarget) return
    const holder = this.scrollTarget

    const onWheel = (event) => {
      const hasHorizontalOverflow = holder.scrollWidth > holder.clientWidth
      if (!hasHorizontalOverflow || event.deltaY === 0) return

      const atTop = holder.scrollTop <= 0
      const atBottom = holder.scrollTop + holder.clientHeight >= holder.scrollHeight - 1
      const hasVerticalOverflow = holder.scrollHeight > holder.clientHeight
      const isVerticalBoundary = !hasVerticalOverflow || (event.deltaY < 0 ? atTop : atBottom)
      if (!event.shiftKey && !isVerticalBoundary) return

      holder.scrollLeft += event.deltaY
      event.preventDefault()
    }

    let dragState = null
    let suppressUntil = 0

    const startDrag = (event) => {
      if (event.pointerType !== "mouse") return
      if (event.button !== 0) return
      if (event.target.closest(INTERACTIVE_SELECTOR)) return

      dragState = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        startLeft: holder.scrollLeft,
        startTop: holder.scrollTop,
        moved: false,
      }

      holder.classList.add("story-scroll-dragging")
      document.body.classList.add("tabulator-user-select-lock")
    }

    const moveDrag = (event) => {
      if (!dragState || event.pointerId !== dragState.pointerId) return

      const dx = event.clientX - dragState.startX
      const dy = event.clientY - dragState.startY
      if (!dragState.moved && (Math.abs(dx) > 2 || Math.abs(dy) > 2)) {
        dragState.moved = true
      }

      holder.scrollLeft = dragState.startLeft - dx
      holder.scrollTop = dragState.startTop - dy
    }

    const endDrag = (event) => {
      if (!dragState || event.pointerId !== dragState.pointerId) return
      if (dragState.moved) suppressUntil = Date.now() + 120

      dragState = null
      holder.classList.remove("story-scroll-dragging")
      document.body.classList.remove("tabulator-user-select-lock")
    }

    const suppressClickAfterDrag = (event) => {
      if (Date.now() <= suppressUntil) {
        event.preventDefault()
        event.stopPropagation()
      }
    }

    holder.addEventListener("wheel", onWheel, { passive: false })
    holder.addEventListener("pointerdown", startDrag)
    window.addEventListener("pointermove", moveDrag)
    window.addEventListener("pointerup", endDrag)
    window.addEventListener("pointercancel", endDrag)
    holder.addEventListener("click", suppressClickAfterDrag, true)

    this.cleanupScrollEnhancements = () => {
      holder.removeEventListener("wheel", onWheel)
      holder.removeEventListener("pointerdown", startDrag)
      holder.removeEventListener("click", suppressClickAfterDrag, true)
      window.removeEventListener("pointermove", moveDrag)
      window.removeEventListener("pointerup", endDrag)
      window.removeEventListener("pointercancel", endDrag)
      holder.classList.remove("story-scroll-dragging")
      document.body.classList.remove("tabulator-user-select-lock")
    }
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
