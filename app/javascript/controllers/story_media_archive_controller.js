import { Controller } from "@hotwired/stimulus"
import { getCableConsumer } from "../lib/cable_consumer"
import { notifyApp } from "../lib/notifications"

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
    this.storyReplyConsumer = null
    this.storyReplySubscription = null
    this.storyReplyWsConnected = false
    this.modalEl = null
    this.bootstrapped = false
    this.boundHandleModalKeydown = this.handleModalKeydown.bind(this)
    this.boundHandleLlmStateChanged = this.handleLlmStateChanged.bind(this)
    this.lastRefreshSignalValue = this.readRefreshSignalValue()
    this.installRefreshSignalObserver()
    this.installScrollEnhancements()
    this.ensureStoryReplySubscription()
    window.addEventListener("llm-comment:state-changed", this.boundHandleLlmStateChanged)

    this.loaderTarget.hidden = false
    this.loaderTarget.textContent = "Archive idle. Click Load Archive to fetch media."

    if (this.autoloadValue) {
      this.bootstrap()
    }
  }

  disconnect() {
    this.closeStoryModal()
    this.teardownStoryReplySubscription()
    if (this.refreshObserver) this.refreshObserver.disconnect()
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    if (this.initialRefreshTimer) clearTimeout(this.initialRefreshTimer)
    if (this.initialRefreshIdleId && "cancelIdleCallback" in window) window.cancelIdleCallback(this.initialRefreshIdleId)
    this.cleanupScrollEnhancements?.()
    window.removeEventListener("llm-comment:state-changed", this.boundHandleLlmStateChanged)
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
    const storyIdentifier = item.story_id ? `Story #${item.story_id}` : `Story Event #${eventId}`
    const postedAt = this.formatDate(item.story_posted_at || item.downloaded_at)
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
          <p class="story-card-title"><strong>${this.esc(storyIdentifier)}</strong></p>
          <p class="meta">${this.esc(postedAt)}</p>
          ${this.buildLlmCommentSection(item)}
        </div>
      </article>
    `
  }

  buildLlmCommentSection(item) {
    const state = this.resolveLlmCardState({
      status: item.llm_comment_status,
      workflowStatus: item.llm_workflow_status,
      hasComment: item.has_llm_comment,
      generatedComment: item.llm_generated_comment,
    })
    const manual = this.resolveManualSendState(item.manual_send_status)
    const manualMessage = this.manualSendMessageForItem(item, manual)
    const generatedAt = this.formatDate(item.llm_comment_generated_at)
    const forceRegenerate = state.code === "completed"
    const progressText = this.compactProgressText(
      item.llm_processing_stages,
      item.llm_workflow_status || item.llm_comment_status,
      item.llm_workflow_progress
    )
    const stageLastText = this.formatLastStageText(this.latestStageFromItem(item))
    const modelSummary = this.renderModelSummary(item, { compact: true })
    const diagnostics = this.renderDecisionDiagnostics(item, { llmState: state, manualState: manual, compact: true })

    return `
      <div class="llm-comment-section" data-event-id="${this.esc(String(item.id))}" data-llm-status="${this.esc(state.code)}">
        <div class="llm-comment-header">
          <span class="story-status-chip ${this.esc(state.chipClass)}" data-role="llm-status">${this.esc(state.label)}</span>
          <p class="meta llm-completion-row ${state.code === "completed" ? "" : "hidden"}" data-role="llm-completion">Completed ${this.esc(generatedAt)}</p>
        </div>
        <p class="meta llm-progress-compact ${progressText ? "" : "hidden"}" data-role="llm-progress-compact">${this.esc(progressText || "")}</p>
        <p class="meta llm-stage-last ${stageLastText ? "" : "hidden"}" data-role="llm-stage-last">${stageLastText ? `Latest: ${this.esc(stageLastText)}` : ""}</p>
        ${modelSummary}
        ${diagnostics}
        <div class="manual-send-state" data-event-id="${this.esc(String(item.id))}" data-manual-status="${this.esc(manual.code)}">
          <span class="story-status-chip ${this.esc(manual.chipClass)}" data-role="manual-send-status">${this.esc(manual.label)}</span>
          <p class="meta ${manualMessage ? "" : "hidden"}" data-role="manual-send-message">${this.esc(manualMessage || "")}</p>
        </div>
        <div class="llm-card-actions">
          ${this.renderPrimarySendButton(item, manual, { className: "btn small secondary", baseLabel: "Send" })}
          <button
            type="button"
            class="btn small secondary generate-comment-btn ${state.inFlight ? "loading" : ""}"
            data-event-id="${this.esc(String(item.id))}"
            data-generate-force="${forceRegenerate ? "true" : "false"}"
            data-generate-all="false"
            data-action="click->llm-comment#generateComment"
            ${state.inFlight ? "disabled" : ""}
          >
            ${this.esc(state.buttonLabel)}
          </button>
          <button
            type="button"
            class="btn small secondary"
            data-event-id="${this.esc(String(item.id))}"
            data-action="click->story-media-archive#openStoryModal"
          >
            View Details
          </button>
        </div>
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

  handleLlmStateChanged(event) {
    const detail = event?.detail && typeof event.detail === "object" ? event.detail : {}
    const eventId = String(detail?.eventId || "").trim()
    if (!eventId) return

    const existing = this.itemsById.get(eventId)
    if (!existing) return

    const patch = detail?.patch && typeof detail.patch === "object" ? detail.patch : {}
    if (Object.keys(patch).length === 0) return

    const merged = this.mergeArchiveItem(existing, patch)
    this.itemsById.set(eventId, merged)
    if (this.shouldRerenderCardForPatch(patch)) {
      this.refreshCardCommentSection(eventId)
    }
    if (this.shouldRerenderModalForPatch(patch)) {
      this.refreshOpenModalForEvent(eventId)
    }
  }

  shouldRerenderCardForPatch(patch) {
    if (!patch || typeof patch !== "object") return false
    if (Object.prototype.hasOwnProperty.call(patch, "llm_generated_comment")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_comment_generated_at")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_ranked_candidates")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_workflow_status")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_workflow_progress")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_comment_status")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_comment_last_error")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_manual_review_reason")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_generation_policy")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_reason_code")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_source")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_message")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_model_label")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_status")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_reason")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_message")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_last_error")) return true
    return false
  }

  shouldRerenderModalForPatch(patch) {
    if (!patch || typeof patch !== "object") return false
    if (Object.prototype.hasOwnProperty.call(patch, "llm_generated_comment")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_comment_generated_at")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_ranked_candidates")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_comment_last_error")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_pipeline_step_rollup")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_pipeline_timing")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_generation_policy")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_manual_review_reason")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_reason_code")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_source")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_failure_message")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "llm_model_label")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_status")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_reason")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_message")) return true
    if (Object.prototype.hasOwnProperty.call(patch, "manual_send_last_error")) return true
    if (!Object.prototype.hasOwnProperty.call(patch, "llm_comment_status")) return false

    const status = String(patch.llm_comment_status || "").toLowerCase()
    return status === "completed" || status === "failed" || status === "skipped"
  }

  mergeArchiveItem(existing, patch) {
    const merged = { ...existing, ...patch }
    const existingStages = existing?.llm_processing_stages && typeof existing.llm_processing_stages === "object" ? existing.llm_processing_stages : {}
    const patchStages = patch?.llm_processing_stages && typeof patch.llm_processing_stages === "object" ? patch.llm_processing_stages : {}
    if (Object.keys(patchStages).length > 0) {
      merged.llm_processing_stages = this.mergeStageMaps(existingStages, patchStages)
    }

    if (Array.isArray(patch?.llm_processing_log) && patch.llm_processing_log.length > 0) {
      merged.llm_processing_log = patch.llm_processing_log
    }
    if (patch?.llm_pipeline_step_rollup && typeof patch.llm_pipeline_step_rollup === "object") {
      merged.llm_pipeline_step_rollup = patch.llm_pipeline_step_rollup
    }
    if (patch?.llm_pipeline_timing && typeof patch.llm_pipeline_timing === "object") {
      merged.llm_pipeline_timing = patch.llm_pipeline_timing
    }
    if (patch?.llm_generation_policy && typeof patch.llm_generation_policy === "object") {
      const currentPolicy = existing?.llm_generation_policy && typeof existing.llm_generation_policy === "object" ? existing.llm_generation_policy : {}
      merged.llm_generation_policy = { ...currentPolicy, ...patch.llm_generation_policy }
    }
    if (typeof patch?.llm_workflow_status === "string" && patch.llm_workflow_status.length > 0) {
      merged.llm_workflow_status = patch.llm_workflow_status
    }
    if (patch?.llm_workflow_progress && typeof patch.llm_workflow_progress === "object") {
      merged.llm_workflow_progress = patch.llm_workflow_progress
    }
    if (String(merged.llm_generated_comment || "").trim().length > 0) {
      merged.has_llm_comment = true
    }
    return merged
  }

  mergeStageMaps(primary, secondary) {
    const merged = {}
    const append = (input) => {
      if (!input || typeof input !== "object") return
      Object.entries(input).forEach(([key, value]) => {
        if (!value || typeof value !== "object") return
        const current = merged[key] && typeof merged[key] === "object" ? merged[key] : {}
        merged[key] = { ...current, ...value }
      })
    }
    append(primary)
    append(secondary)
    return merged
  }

  refreshCardCommentSection(eventId) {
    const key = String(eventId || "").trim()
    if (!key) return
    const item = this.itemsById.get(key)
    if (!item) return

    document
      .querySelectorAll(`.story-media-card[data-event-id="${this.escapeSelector(key)}"] .llm-comment-section`)
      .forEach((section) => {
        section.outerHTML = this.buildLlmCommentSection(item)
      })
  }

  refreshOpenModalForEvent(eventId) {
    if (!this.modalEl) return
    const modal = this.modalEl.querySelector(".story-modal")
    if (!modal) return
    if (String(modal.dataset.eventId || "") !== String(eventId)) return

    const item = this.itemsById.get(String(eventId))
    if (!item) return

    const scrollTop = modal.scrollTop
    this.modalEl.innerHTML = this.modalHtml(item)
    const nextModal = this.modalEl.querySelector(".story-modal")
    if (nextModal) nextModal.scrollTop = scrollTop
  }

  modalHtml(item) {
    const contentType = String(item.media_content_type || "")
    const isVideo = contentType.startsWith("video/")
    const videoStatic = this.videoIsStatic(item)
    const posterUrl = this.videoPosterUrl(item)
    const downloaded = this.formatDate(item.downloaded_at)
    const posted = this.formatDate(item.story_posted_at || item.downloaded_at)
    const mediaSize = this.formatBytes(item.media_bytes)
    const dimensions = (item.media_width && item.media_height) ? `${item.media_width}x${item.media_height}` : "-"
    const storyIdentifier = item.story_id ? `#${item.story_id}` : `event-${item.id}`
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

    const llmState = this.resolveLlmCardState({
      status: item.llm_comment_status,
      workflowStatus: item.llm_workflow_status,
      hasComment: item.has_llm_comment,
      generatedComment: item.llm_generated_comment,
    })
    const manual = this.resolveManualSendState(item.manual_send_status)
    const manualMessage = this.manualSendMessageForItem(item, manual)
    const llmFailed = llmState.code === "failed"
    const llmSkipped = llmState.code === "skipped"
    const llmLabel = llmState.code === "completed" ? "Regenerate" : (llmFailed || llmSkipped ? "Retry Generation" : llmState.buttonLabel)
    const llmHint = llmState.inFlight ?
      "Comment generation is processing in the background." :
      (llmState.code === "completed" ? "Use regenerate to rerun analysis with latest context." : "Runs in background and updates this archive automatically.")
    const llmError = item.llm_comment_last_error_preview || item.llm_comment_last_error
    const suggestions = Array.isArray(item.llm_ranked_candidates) ? item.llm_ranked_candidates : []
    const breakdown = item.llm_relevance_breakdown && typeof item.llm_relevance_breakdown === "object" ? item.llm_relevance_breakdown : {}
    const processingDetails = this.renderProcessingDetailsSection(item)
    const contextSummary = this.renderContextAndFaceSummary(item)
    const modelSummary = this.renderModelSummary(item, { compact: false })
    const decisionDetails = this.renderDecisionDiagnostics(item, { llmState, manualState: manual, compact: false })
    const comment = item.llm_generated_comment ?
      `
        <section class="story-modal-section">
          <h4>AI Suggestion</h4>
          <p class="llm-generated-comment">${this.esc(item.llm_generated_comment)}</p>
          ${this.renderRelevanceBreakdown(breakdown)}
          <div class="llm-card-actions">
            ${this.renderPrimarySendButton(item, manual, { className: "btn secondary", baseLabel: "Send" })}
            <button
              type="button"
              class="btn secondary generate-comment-btn ${llmState.inFlight ? "loading" : ""}"
              data-event-id="${this.esc(String(item.id))}"
              data-generate-force="${llmState.code === "completed" ? "true" : "false"}"
              data-generate-all="false"
              data-action="click->llm-comment#generateComment"
              ${llmState.inFlight ? "disabled" : ""}
            >
              ${this.esc(llmLabel)}
            </button>
            ${this.renderRegenerateAllButton(item, llmState)}
          </div>
          ${this.renderSuggestionPreviewList(item, suggestions)}
        </section>
      ` :
      `
        <section class="story-modal-section">
          <h4>Generate Suggestion</h4>
          <button
            type="button"
            class="btn secondary generate-comment-btn ${llmState.inFlight ? "loading" : ""}"
            data-event-id="${this.esc(String(item.id))}"
            data-generate-force="${llmState.code === "completed" ? "true" : "false"}"
            data-generate-all="false"
            data-action="click->llm-comment#generateComment"
            ${llmState.inFlight ? "disabled" : ""}
          >
            ${this.esc(llmLabel)}
          </button>
          ${this.renderRegenerateAllButton(item, llmState)}
          <p class="meta llm-progress-hint">${this.esc(llmHint)}</p>
          ${this.renderSuggestionPreviewList(item, suggestions)}
          ${llmFailed && llmError ? `<p class="meta error-text">Last error: ${this.esc(llmError)}</p>` : ""}
          ${llmSkipped && llmError ? `<p class="meta">Skipped: ${this.esc(llmError)}</p>` : ""}
        </section>
      `

    return `
      <div class="story-modal" role="dialog" aria-modal="true" aria-label="Story details" data-event-id="${this.esc(String(item.id))}">
        <div class="story-modal-header">
          <h3>Story Archive Item</h3>
          <button type="button" class="modal-close" data-modal-close="story" aria-label="Close story modal">&times;</button>
        </div>

        <div class="story-modal-content">
          <div class="story-detail-view">
            <div class="story-detail-media">${mediaHtml}</div>
            <div class="story-detail-info">
              <p><strong>Profile:</strong> @${this.esc(item.profile_username || "unknown")}</p>
              <p class="meta"><strong>Story ID:</strong> ${this.esc(storyIdentifier)}</p>
              <p class="meta"><strong>Posted:</strong> ${this.esc(posted)}</p>
              <p class="meta"><strong>Downloaded:</strong> ${this.esc(downloaded)}</p>
              <div class="manual-send-state" data-event-id="${this.esc(String(item.id))}" data-manual-status="${this.esc(manual.code)}">
                <p class="meta"><strong>Manual send:</strong> <span class="story-status-chip ${this.esc(manual.chipClass)}" data-role="manual-send-status">${this.esc(manual.label)}</span></p>
                <p class="meta ${manualMessage ? "" : "hidden"}" data-role="manual-send-message">${this.esc(manualMessage || "")}</p>
              </div>
              <section class="story-modal-section">
                <h4>Image Metadata</h4>
                <p class="meta"><strong>Type:</strong> ${this.esc(contentType || "-")}</p>
                <p class="meta"><strong>Size:</strong> ${this.esc(mediaSize)}</p>
                <p class="meta"><strong>Dimensions:</strong> ${this.esc(dimensions)}</p>
              </section>
              ${videoStatic ? `<p class="meta"><strong>Playback mode:</strong> Static visual + optional audio/video playback.</p>` : ""}
              ${item.reply_comment ? `<p><strong>Reply sent:</strong> ${this.esc(item.reply_comment)}</p>` : ""}
              ${item.skipped && item.skip_reason ? `<p class="meta story-skipped-badge">Skipped: ${this.esc(item.skip_reason)}</p>` : ""}
              ${contextSummary}
              ${modelSummary}
              ${decisionDetails}
              ${comment}
              ${processingDetails}
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

  renderPrimarySendButton(item, manualState, { className = "btn secondary", baseLabel = "Send" } = {}) {
    const commentText = String(item?.llm_generated_comment || "").trim()
    if (!commentText) return ""

    const sendDisabled = manualState.sending || manualState.code === "sent" || manualState.code === "expired_removed"
    const sendLabel = manualState.sending ? "Sending..." : (manualState.code === "sent" ? "Sent" : (manualState.code === "expired_removed" ? "Expired" : baseLabel))

    return `
      <button
        type="button"
        class="${this.esc(className)} manual-send-btn"
        data-event-id="${this.esc(String(item.id))}"
        data-comment-text="${this.esc(commentText)}"
        data-base-label="${this.esc(baseLabel)}"
        data-action="click->story-media-archive#sendSuggestion"
        ${sendDisabled ? "disabled" : ""}
      >
        ${this.esc(sendLabel)}
      </button>
    `
  }

  renderRegenerateAllButton(item, llmState) {
    if (llmState?.inFlight) return ""

    const status = String(item?.llm_comment_status || "").toLowerCase()
    const hasPipelineData = item?.llm_pipeline_step_rollup && typeof item.llm_pipeline_step_rollup === "object" &&
      Object.keys(item.llm_pipeline_step_rollup).length > 0
    const canShow = status === "completed" || status === "failed" || status === "skipped" || hasPipelineData
    if (!canShow) return ""

    return `
      <button
        type="button"
        class="btn secondary generate-comment-all-btn"
        data-event-id="${this.esc(String(item.id))}"
        data-generate-force="true"
        data-generate-all="true"
        data-action="click->llm-comment#generateComment"
      >
        Regenerate All
      </button>
    `
  }

  compactProgressText(stageMap, status, workflowProgress = null) {
    if (workflowProgress && typeof workflowProgress === "object") {
      const summary = String(workflowProgress.summary || "").trim()
      if (summary) return summary
    }

    const entries = this.normalizeStageEntries(stageMap)
    const normalizedStatus = String(status || "").toLowerCase()
    if (entries.length === 0 && !["queued", "running", "started", "completed", "failed", "error", "skipped"].includes(normalizedStatus)) {
      return ""
    }

    const phaseStates = this.phaseStates(entries)
    const total = phaseStates.length
    const completed = phaseStates.filter((row) => row.state === "completed").length

    if (normalizedStatus === "completed") return `${total} of ${total} completed`
    if (normalizedStatus === "queued") return `${completed} of ${total} completed (queued)`
    if (normalizedStatus === "failed" || normalizedStatus === "error") return `${completed} of ${total} completed (failed)`
    if (normalizedStatus === "skipped") return `${completed} of ${total} completed (skipped)`
    return `${completed} of ${total} completed`
  }

  async sendSuggestion(event) {
    event.preventDefault()
    const button = event.currentTarget
    const eventId = button?.dataset?.eventId || button?.closest("[data-event-id]")?.dataset?.eventId
    const text = String(button?.dataset?.commentText || "").trim()
    if (!eventId || !text) return

    this.updateManualSendState(eventId, {
      status: "sending",
      message: "Sending comment...",
      reason: "manual_send_requested",
      comment_text: text,
    })

    try {
      const response = await fetch(`/instagram_accounts/${this.accountIdValue}/resend_story_reply`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.getCsrfToken(),
          Accept: "application/json",
        },
        body: JSON.stringify({
          event_id: eventId,
          comment_text: text,
        }),
      })
      const payload = await response.json().catch(() => ({}))
      const status = String(payload?.status || "").toLowerCase()
      this.updateManualSendState(eventId, payload)

      if (!response.ok) {
        if (!status || status === "sending") {
          this.updateManualSendState(eventId, {
            status: "failed",
            error: payload?.error || `Request failed (${response.status})`,
            message: payload?.error || "Manual send failed.",
          })
        }
        throw new Error(payload.error || `Request failed (${response.status})`)
      }

      if (status === "sent") {
        notifyApp(payload?.already_posted ? "Comment already posted for this story." : "Comment sent manually.", "success")
      } else if (status === "expired_removed") {
        notifyApp("Story is unavailable (expired or removed).", "notice")
      } else if (status === "failed") {
        notifyApp(`Manual send failed: ${payload?.error || payload?.reason || "Unknown error"}`, "error")
      }
    } catch (error) {
      notifyApp(`Manual send failed: ${error.message}`, "error")
    }
  }

  getCsrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  ensureStoryReplySubscription() {
    if (!Number.isFinite(this.accountIdValue) || this.accountIdValue <= 0) return
    if (this.storyReplySubscription) return

    try {
      this.storyReplyConsumer = getCableConsumer()
      if (!this.storyReplyConsumer?.subscriptions || typeof this.storyReplyConsumer.subscriptions.create !== "function") return

      this.storyReplySubscription = this.storyReplyConsumer.subscriptions.create(
        {
          channel: "StoryReplyStatusChannel",
          account_id: this.accountIdValue,
        },
        {
          connected: () => {
            this.storyReplyWsConnected = true
          },
          disconnected: () => {
            this.storyReplyWsConnected = false
          },
          rejected: () => {
            this.storyReplyWsConnected = false
          },
          received: (data) => this.updateManualSendState(data?.event_id, data),
        },
      )
    } catch (_error) {
      this.storyReplyWsConnected = false
      this.storyReplySubscription = null
      this.storyReplyConsumer = null
    }
  }

  teardownStoryReplySubscription() {
    if (!this.storyReplyConsumer || !this.storyReplySubscription) return
    try {
      this.storyReplyConsumer.subscriptions.remove(this.storyReplySubscription)
    } catch (_error) {
      // no-op
    }
    this.storyReplySubscription = null
    this.storyReplyConsumer = null
    this.storyReplyWsConnected = false
  }

  updateManualSendState(eventId, payload = {}) {
    const key = String(eventId || "").trim()
    if (!key) return

    const state = this.resolveManualSendState(payload?.status)
    const message = this.manualSendMessageForPayload(payload, state)
    const reason = String(payload?.reason || "").trim()
    const error = String(payload?.error || "").trim()
    const updatedAt = payload?.updated_at || payload?.manual_send_updated_at || null
    const commentText = payload?.comment_text || payload?.manual_send_last_comment || null

    const item = this.itemsById.get(key)
    if (item) {
      item.manual_send_status = state.code
      item.manual_send_reason = reason || item.manual_send_reason
      item.manual_send_message = message || item.manual_send_message
      item.manual_send_last_error = error || (state.code === "failed" ? item.manual_send_last_error : null)
      item.manual_send_updated_at = updatedAt || item.manual_send_updated_at
      if (state.code === "sent") {
        item.manual_send_last_sent_at = updatedAt || item.manual_send_last_sent_at
        if (commentText) item.reply_comment = commentText
      }
      if (commentText) item.manual_send_last_comment = commentText
    }

    document
      .querySelectorAll(`.manual-send-state[data-event-id="${this.escapeSelector(key)}"]`)
      .forEach((section) => {
        section.dataset.manualStatus = state.code

        const statusEl = section.querySelector("[data-role='manual-send-status']")
        if (statusEl) {
          statusEl.textContent = state.label
          statusEl.classList.remove("idle", "queued", "in-progress", "completed", "failed", "skipped")
          statusEl.classList.add(state.chipClass)
        }

        const messageEl = section.querySelector("[data-role='manual-send-message']")
        if (messageEl) {
          if (message) {
            messageEl.textContent = message
            messageEl.classList.remove("hidden")
          } else {
            messageEl.textContent = ""
            messageEl.classList.add("hidden")
          }
        }
      })

    this.updateManualSendButtonsForEvent(key, state)
    this.refreshCardCommentSection(key)
    this.refreshOpenModalForEvent(key)
  }

  resolveManualSendState(status) {
    const normalized = String(status || "").toLowerCase().trim()
    if (normalized === "sending" || normalized === "queued" || normalized === "running") {
      return { code: "sending", label: "Sending", chipClass: "in-progress", sending: true }
    }
    if (normalized === "sent") {
      return { code: "sent", label: "Sent", chipClass: "completed", sending: false }
    }
    if (normalized === "failed" || normalized === "error") {
      return { code: "failed", label: "Failed", chipClass: "failed", sending: false }
    }
    if (normalized === "expired_removed" || normalized === "expired" || normalized === "removed") {
      return { code: "expired_removed", label: "Expired / Removed", chipClass: "skipped", sending: false }
    }
    return { code: "ready", label: "Ready", chipClass: "idle", sending: false }
  }

  manualSendMessageForPayload(payload, state) {
    const explicitMessage = String(payload?.message || "").trim()
    const error = String(payload?.error || "").trim()
    if (error) return error
    if (explicitMessage) return explicitMessage
    if (state.code === "sending") return "Sending comment..."
    if (state.code === "expired_removed") return "Story expired or removed."
    if (state.code === "failed") return "Manual send failed. Retry is available."
    return ""
  }

  manualSendMessageForItem(item, manualState) {
    const explicitMessage = String(item?.manual_send_message || "").trim()
    const explicitError = String(item?.manual_send_last_error || "").trim()
    if (explicitError) return explicitError
    if (explicitMessage) return explicitMessage

    if (manualState.code === "sent") {
      const sentAt = this.formatDate(item?.manual_send_last_sent_at || item?.manual_send_updated_at)
      return sentAt !== "-" ? `Sent ${sentAt}` : "Comment sent."
    }
    if (manualState.code === "sending") return "Sending comment..."
    if (manualState.code === "expired_removed") return "Story expired or removed."
    if (manualState.code === "failed") return "Manual send failed. Retry is available."
    return ""
  }

  updateManualSendButtonsForEvent(eventId, state) {
    const key = String(eventId)
    document
      .querySelectorAll(`.manual-send-btn[data-event-id="${this.escapeSelector(key)}"]`)
      .forEach((button) => {
        const baseLabel = String(button.dataset.baseLabel || "Send manually")
        if (state.code === "sending") {
          button.disabled = true
          button.textContent = "Sending..."
          return
        }
        if (state.code === "sent") {
          button.disabled = true
          button.textContent = "Sent"
          return
        }
        if (state.code === "expired_removed") {
          button.disabled = true
          button.textContent = "Expired"
          return
        }

        button.disabled = false
        button.textContent = baseLabel
      })
  }

  renderSuggestionPreviewList(item, suggestions) {
    const rows = Array.isArray(suggestions) ? suggestions : []
    if (rows.length === 0) return ""

    const html = rows
      .slice(0, 5)
      .map((row) => {
        const comment = String(row?.comment || "").trim()
        if (!comment) return ""
        const score = Number(row?.score)
        const scoreText = Number.isFinite(score) ? ` (${score.toFixed(2)})` : ""
        return `<li>${this.esc(comment)}${this.esc(scoreText)}</li>`
      })
      .join("")

    return `
      <div class="llm-suggestions-preview">
        <p class="meta"><strong>Top candidate comments:</strong></p>
        <ul class="meta">${html}</ul>
      </div>
    `
  }

  renderRelevanceBreakdown(breakdown) {
    if (!breakdown || typeof breakdown !== "object") return ""
    const keys = [
      ["visual_context", "Visual context"],
      ["ocr_text", "OCR text"],
      ["user_context_match", "User context match"],
      ["engagement_relevance", "Engagement relevance"],
    ]
    const rows = keys
      .map(([key, label]) => {
        const value = breakdown[key]
        if (!value || typeof value !== "object") return ""
        const level = String(value.label || "low")
        const score = Number(value.value)
        const scoreText = Number.isFinite(score) ? ` (${score.toFixed(2)})` : ""
        return `<li>${this.esc(label)}: ${this.esc(level)}${this.esc(scoreText)}</li>`
      })
      .filter(Boolean)
      .join("")
    if (!rows) return ""
    return `<ul class="meta llm-relevance-breakdown">${rows}</ul>`
  }

  renderProcessingDetailsSection(item) {
    const timing = this.renderPipelineTiming(item)
    const stageList = this.renderStageList(item.llm_processing_stages)
    const logList = this.renderProcessingLog(item.llm_processing_log)
    if (!timing && !stageList && !logList) return ""

    const summary = this.compactProgressText(
      item.llm_processing_stages,
      item.llm_workflow_status || item.llm_comment_status,
      item.llm_workflow_progress
    )
    const status = String(item.llm_workflow_status || item.llm_comment_status || "").toLowerCase()
    const shouldOpen = status === "running" || status === "queued" || status === "started"

    return `
      <section class="story-modal-section">
        <details class="llm-processing-details" data-role="llm-processing-details" data-event-id="${this.esc(String(item.id))}" ${shouldOpen ? "open" : ""}>
          <summary>
            <span>AI Processing Details</span>
            ${summary ? `<span class="meta">${this.esc(summary)}</span>` : ""}
          </summary>
          ${timing}
          ${stageList}
          ${logList}
        </details>
      </section>
    `
  }

  renderPipelineTiming(item) {
    const stepRollup = item?.llm_pipeline_step_rollup && typeof item.llm_pipeline_step_rollup === "object" ? item.llm_pipeline_step_rollup : {}
    const timing = item?.llm_pipeline_timing && typeof item.llm_pipeline_timing === "object" ? item.llm_pipeline_timing : {}

    const stepRows = this.pipelineStepKeys()
      .map((key) => ({ key, row: stepRollup[key] }))
      .filter(({ row }) => row && typeof row === "object")

    const totalMs = Number(timing?.pipeline_duration_ms)
    const generationMs = Number(timing?.generation_duration_ms)
    const hasTiming = Number.isFinite(totalMs) || Number.isFinite(generationMs)
    if (stepRows.length === 0 && !hasTiming) return ""

    const summaryParts = []
    if (Number.isFinite(totalMs)) summaryParts.push(`Total ${this.formatDurationMs(totalMs)}`)
    if (Number.isFinite(generationMs)) summaryParts.push(`Generation ${this.formatDurationMs(generationMs)}`)
    const summaryText = summaryParts.join(" | ")

    const rowHtml = stepRows.map(({ key, row }) => {
      const waitMs = Number(row?.queue_wait_ms)
      const runMs = Number(row?.run_duration_ms)
      const totalStepMs = Number(row?.total_duration_ms)
      const status = this.stageStateLabel(String(row?.status || "pending"), null)

      return `
        <tr>
          <td>${this.esc(this.humanizeStageKey(key))}</td>
          <td>${this.esc(status)}</td>
          <td>${this.esc(this.formatDurationMs(waitMs))}</td>
          <td>${this.esc(this.formatDurationMs(runMs))}</td>
          <td>${this.esc(this.formatDurationMs(totalStepMs))}</td>
        </tr>
      `
    }).join("")

    return `
      <div class="llm-processing-block">
        <h4>Queue & Timing</h4>
        ${summaryText ? `<p class="meta">${this.esc(summaryText)}</p>` : ""}
        <div class="table-scroll">
          <table class="table llm-timing-table">
            <thead>
              <tr>
                <th>Stage</th>
                <th>Status</th>
                <th>Wait</th>
                <th>Run</th>
                <th>Total</th>
              </tr>
            </thead>
            <tbody>${rowHtml}</tbody>
          </table>
        </div>
      </div>
    `
  }

  pipelineStepKeys() {
    return ["ocr_analysis", "vision_detection", "face_recognition", "metadata_extraction"]
  }

  renderStageList(stages) {
    if (!stages || typeof stages !== "object") return ""
    const rows = this.normalizeStageEntries(stages)
      .slice(0, 12)
      .map((row) => {
        const label = String(row.label || "Stage")
        const stateLabel = this.stageStateLabel(row.state, row.progress)
        return `<li>${this.esc(label)} -> ${this.esc(stateLabel)}</li>`
      }).join("")
    if (!rows) return ""
    return `
      <div class="llm-processing-block">
        <h4>Stage Progress</h4>
        <ul class="meta llm-progress-steps">${rows}</ul>
      </div>
    `
  }

  renderProcessingLog(logRows) {
    const rows = Array.isArray(logRows) ? logRows.slice(-10) : []
    if (rows.length === 0) return ""

    const logHtml = rows
      .map((row) => {
        const stage = String(row?.stage || "stage")
        const message = String(row?.message || "").trim()
        const state = String(row?.state || "pending")
        const at = this.formatDate(row?.at)
        const messagePart = message ? `: ${message}` : ""
        return `<li>${this.esc(stage)} (${this.esc(state)})${this.esc(messagePart)} - ${this.esc(at)}</li>`
      })
      .join("")

    return `
      <div class="llm-processing-block">
        <h4>Event Log</h4>
        <ul class="meta llm-progress-steps">${logHtml}</ul>
      </div>
    `
  }

  normalizeStageEntries(stageMap) {
    if (!stageMap || typeof stageMap !== "object") return []
    return Object.entries(stageMap)
      .filter(([, row]) => row && typeof row === "object")
      .map(([key, row]) => {
        const label = String(row?.label || this.humanizeStageKey(key))
        const state = String(row?.state || "pending").toLowerCase()
        const progress = Number(row?.progress)
        const providedOrder = Number(row?.order)
        return {
          key: String(key),
          label,
          state,
          progress: Number.isFinite(progress) ? progress : null,
          order: Number.isFinite(providedOrder) ? providedOrder : this.stageSortWeight(key),
        }
      })
      .sort((a, b) => {
        if (a.order !== b.order) return a.order - b.order
        return a.label.localeCompare(b.label)
      })
  }

  stageSortWeight(stageKey) {
    const order = {
      queue_wait: 5,
      parallel_services: 10,
      ocr_analysis: 20,
      vision_detection: 24,
      face_recognition: 28,
      metadata_extraction: 32,
      context_matching: 40,
      prompt_construction: 50,
      llm_generation: 60,
      relevance_scoring: 70,
      engagement_eligibility: 80,
      reply_send_action: 90,
    }
    return Number(order[String(stageKey)] || 900)
  }

  stageStateLabel(state, progress) {
    const normalized = String(state || "pending").toLowerCase()
    if (normalized === "completed") return "Completed"
    if (normalized === "completed_with_warnings") return "Completed (Warnings)"
    if (normalized === "running" || normalized === "started") {
      return Number.isFinite(progress) ? `In Progress (${Math.round(progress)}%)` : "In Progress"
    }
    if (normalized === "queued") return "Queued"
    if (normalized === "failed" || normalized === "error") return "Failed"
    if (normalized === "skipped") return "Skipped"
    return "Pending"
  }

  phaseStates(entries) {
    const stateByKey = new Map()
    entries.forEach((entry) => stateByKey.set(String(entry.key), String(entry.state || "pending").toLowerCase()))

    const phases = [
      ["analysis", ["parallel_services", "ocr_analysis", "vision_detection", "metadata_extraction"]],
      ["context", ["context_matching", "prompt_construction"]],
      ["generation", ["llm_generation", "relevance_scoring"]],
      ["eligibility", ["engagement_eligibility"]],
      ["send", ["reply_send_action"]],
    ]

    return phases.map(([, keys]) => {
      const states = keys.map((key) => stateByKey.get(key) || "pending")
      if (states.some((state) => state === "failed" || state === "error")) return { state: "failed" }
      if (states.every((state) => state === "completed" || state === "completed_with_warnings" || state === "skipped")) return { state: "completed" }
      if (states.some((state) => state === "running" || state === "started" || state === "queued")) return { state: "running" }
      return { state: "pending" }
    })
  }

  humanizeStageKey(value) {
    const key = String(value || "").trim()
    if (!key) return "Stage"
    return key
      .replace(/[_-]+/g, " ")
      .split(" ")
      .filter(Boolean)
      .map((token) => token.charAt(0).toUpperCase() + token.slice(1))
      .join(" ")
  }

  renderContextAndFaceSummary(item) {
    const label = String(item.story_ownership_label || "").trim()
    const summary = String(item.story_ownership_summary || "").trim()
    const confidence = Number(item.story_ownership_confidence)
    const confidenceText = Number.isFinite(confidence) ? confidence.toFixed(2) : "-"
    if (!label && !summary) return ""

    return `
      <section class="story-modal-section">
        <h4>AI Analysis Summary</h4>
        ${label ? `<p class="meta"><strong>Ownership:</strong> ${this.esc(label)}</p>` : ""}
        ${summary ? `<p class="meta"><strong>Summary:</strong> ${this.esc(summary)}</p>` : ""}
        ${label ? `<p class="meta"><strong>Confidence:</strong> ${this.esc(confidenceText)}</p>` : ""}
      </section>
    `
  }

  renderModelSummary(item, { compact = true } = {}) {
    const provider = String(item?.llm_comment_provider || "").trim()
    const model = String(item?.llm_comment_model || "").trim()
    const explicitLabel = String(item?.llm_model_label || "").trim()
    const contentType = String(item?.media_content_type || "").trim() || "unknown"
    const modelLabel = explicitLabel || (provider && model ? `${provider} / ${model}` : (provider || model || "Pending"))
    const title = compact ? "Model" : "Comment model"
    return `<p class="meta llm-model-row"><strong>${this.esc(title)}:</strong> ${this.esc(modelLabel)} <span class="llm-model-media">(${this.esc(contentType)})</span></p>`
  }

  renderDecisionDiagnostics(item, { llmState = null, manualState = null, compact = true } = {}) {
    const resolvedLlmState = llmState || this.resolveLlmCardState({
      status: item?.llm_comment_status,
      workflowStatus: item?.llm_workflow_status,
      hasComment: item?.has_llm_comment,
      generatedComment: item?.llm_generated_comment,
    })
    const resolvedManualState = manualState || this.resolveManualSendState(item?.manual_send_status)
    const rows = [
      this.llmDecisionReason(item, resolvedLlmState),
      this.manualDecisionReason(item, resolvedManualState),
    ].filter(Boolean)
    if (rows.length === 0) return ""

    const notes = rows.map((row) => {
      const codeLabel = row?.reasonCode ? this.humanizeReasonCode(row.reasonCode) : ""
      const sourceLabel = row?.source ? this.humanizeReasonCode(row.source) : ""
      const metaParts = []
      if (codeLabel) metaParts.push(`Reason: ${codeLabel}`)
      if (sourceLabel) metaParts.push(`Source: ${sourceLabel}`)
      if (row?.rawCode && row.rawCode !== row.reasonCode) metaParts.push(`Code: ${row.rawCode}`)
      return `
        <div class="llm-decision-note ${this.esc(row.levelClass || "info")}">
          <p class="llm-decision-title"><strong>${this.esc(row.title || "Decision")}</strong></p>
          ${row.message ? `<p class="meta llm-decision-message">${this.esc(row.message)}</p>` : ""}
          ${metaParts.length > 0 ? `<p class="meta llm-decision-meta">${this.esc(metaParts.join(" | "))}</p>` : ""}
        </div>
      `
    }).join("")

    if (compact) return `<div class="llm-decision-stack compact">${notes}</div>`

    return `
      <section class="story-modal-section">
        <h4>Decision Details</h4>
        <div class="llm-decision-stack">${notes}</div>
      </section>
    `
  }

  llmDecisionReason(item, llmState) {
    const stateCode = String(llmState?.code || "").toLowerCase()
    const manualReviewReason = String(item?.llm_manual_review_reason || "").trim()
    const failureMessage = this.resolveLlmFailureMessage(item)
    const reasonCodeRaw = String(
      item?.llm_failure_reason_code ||
      item?.llm_policy_reason_code ||
      item?.llm_generation_policy?.reason_code ||
      "",
    ).trim()
    const sourceRaw = String(
      item?.llm_failure_source ||
      item?.llm_policy_source ||
      item?.llm_generation_policy?.source ||
      "",
    ).trim()
    const policyReason = String(item?.llm_policy_reason || item?.llm_generation_policy?.reason || "").trim()
    const allowComment = this.resolveAllowComment(item)
    const autoPostAllowed = this.resolveAutoPostAllowed(item)
    const mediaUnsupported = !this.supportedStoryMediaType(item?.media_content_type)
    const reasonCode = reasonCodeRaw || (mediaUnsupported ? "unsupported_media_type" : "")

    if (stateCode === "completed" && (manualReviewReason || autoPostAllowed === false)) {
      return {
        title: "AI requires manual review",
        message: manualReviewReason || policyReason || "Generated comment is marked for manual verification before sending.",
        reasonCode: reasonCode || "manual_review_required",
        source: sourceRaw || "quality_policy",
        rawCode: reasonCodeRaw,
        levelClass: "warning",
      }
    }

    if (stateCode === "skipped") {
      return {
        title: "AI skipped comment generation",
        message: failureMessage || policyReason || "Comment generation was skipped for this story.",
        reasonCode: reasonCode || "generation_skipped",
        source: sourceRaw || "llm_pipeline",
        rawCode: reasonCodeRaw,
        levelClass: "failed",
      }
    }

    if (stateCode === "failed") {
      return {
        title: "AI generation failed",
        message: failureMessage || policyReason || "The generation pipeline failed before producing a comment.",
        reasonCode: reasonCode || "generation_failed",
        source: sourceRaw || "llm_pipeline",
        rawCode: reasonCodeRaw,
        levelClass: "failed",
      }
    }

    if (allowComment === false) {
      return {
        title: "AI policy blocked generation",
        message: policyReason || "Story policy marked this media as not suitable for auto comment generation.",
        reasonCode: reasonCode || "policy_blocked",
        source: sourceRaw || "validated_story_policy",
        rawCode: reasonCodeRaw,
        levelClass: "warning",
      }
    }

    if (mediaUnsupported && (stateCode === "not_started" || stateCode === "partial")) {
      return {
        title: "Media type may not be supported",
        message: `Detected media type ${String(item?.media_content_type || "unknown")}; AI generation may be skipped.`,
        reasonCode: "unsupported_media_type",
        source: "media_validation",
        rawCode: reasonCodeRaw,
        levelClass: "warning",
      }
    }

    return null
  }

  manualDecisionReason(item, manualState) {
    const code = String(manualState?.code || "").trim()
    if (!["failed", "expired_removed"].includes(code)) return null

    const reasonCodeRaw = String(item?.manual_send_reason || "").trim()
    const reasonCode = reasonCodeRaw || (code === "expired_removed" ? "story_unavailable" : "manual_send_failed")
    const message = String(item?.manual_send_last_error || item?.manual_send_message || "").trim() ||
      (code === "expired_removed" ? "Story expired or was removed before sending." : "Manual send did not complete.")

    return {
      title: code === "expired_removed" ? "Send skipped: story unavailable" : "Send failed",
      message,
      reasonCode,
      source: "manual_send",
      rawCode: reasonCodeRaw,
      levelClass: "failed",
    }
  }

  resolveLlmFailureMessage(item) {
    return String(
      item?.llm_comment_last_error ||
      item?.llm_failure_message ||
      item?.llm_policy_reason ||
      item?.llm_generation_policy?.reason ||
      "",
    ).trim()
  }

  resolveAllowComment(item) {
    if (Object.prototype.hasOwnProperty.call(item || {}, "llm_policy_allow_comment")) {
      const value = this.coerceBoolean(item?.llm_policy_allow_comment)
      return typeof value === "boolean" ? value : null
    }
    if (item?.llm_generation_policy && Object.prototype.hasOwnProperty.call(item.llm_generation_policy, "allow_comment")) {
      const value = this.coerceBoolean(item.llm_generation_policy.allow_comment)
      return typeof value === "boolean" ? value : null
    }
    return null
  }

  resolveAutoPostAllowed(item) {
    if (!Object.prototype.hasOwnProperty.call(item || {}, "llm_auto_post_allowed")) return null
    const value = this.coerceBoolean(item?.llm_auto_post_allowed)
    return typeof value === "boolean" ? value : null
  }

  supportedStoryMediaType(contentType) {
    const value = String(contentType || "").toLowerCase().trim()
    if (!value) return false
    return value.startsWith("image/") || value.startsWith("video/")
  }

  latestStageFromItem(item) {
    const processingLog = Array.isArray(item?.llm_processing_log) ? item.llm_processing_log : []
    for (let index = processingLog.length - 1; index >= 0; index -= 1) {
      const row = processingLog[index]
      if (row && typeof row === "object") return row
    }

    const stageMap = item?.llm_processing_stages && typeof item.llm_processing_stages === "object" ? item.llm_processing_stages : {}
    const rows = Object.entries(stageMap)
      .filter(([, row]) => row && typeof row === "object")
      .map(([key, row]) => ({
        stage: key,
        state: row?.state,
        message: row?.message,
        at: row?.updated_at || null,
        order: this.stageSortWeight(key),
      }))
    if (rows.length === 0) return null

    rows.sort((a, b) => a.order - b.order)
    return rows[rows.length - 1]
  }

  humanizeReasonCode(value) {
    const key = String(value || "").toLowerCase().trim()
    if (!key) return ""

    const labels = {
      vision_model_error: "Vision model error",
      local_ai_extraction_empty: "No usable AI extraction",
      local_story_intelligence_blank: "No local story intelligence",
      identity_likelihood_low: "Low ownership confidence",
      insufficient_verified_signals: "Insufficient verified signals",
      no_historical_overlap_with_external_usernames: "No historical overlap with detected external usernames",
      external_usernames_detected: "Likely third-party or reshared content",
      unsupported_media_type: "Unsupported media type",
      manual_review_required: "Manual review required",
      generation_skipped: "Generation skipped",
      generation_failed: "Generation failed",
      story_unavailable: "Story unavailable",
      missing_story_user_id: "Missing story user id",
      api_story_not_found: "Story not found in API",
      api_can_reply_false: "Replies not allowed by API",
      reply_box_not_found: "Reply UI not available",
      comment_submit_failed: "Comment submission failed",
      policy_blocked: "Blocked by verified story policy",
      quality_policy: "Quality policy review",
      manual_send_failed: "Manual send failed",
      manual_send: "Manual send action",
      llm_pipeline: "LLM processing pipeline",
      validated_story_policy: "Validated story policy",
      media_validation: "Media validation",
      profile_comment_preparation: "Profile context preparation",
      unavailable: "Upstream context unavailable",
      unknown: "Unknown",
    }
    if (labels[key]) return labels[key]
    return key
      .replace(/[_-]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/\b\w/g, (letter) => letter.toUpperCase())
  }

  formatLastStageText(row) {
    if (!row || typeof row !== "object") return ""

    const stage = String(row?.stage || row?.label || "").trim()
    const state = String(row?.state || "").trim().toLowerCase()
    const message = String(row?.message || "").trim()
    const timeValue = row?.at || row?.updated_at || null

    const stageText = stage ? this.humanizeStageKey(stage) : ""
    const stateText = this.stageStateLabel(state, null)
    const at = this.formatDate(timeValue)
    const segments = []
    if (stageText) segments.push(stageText)
    if (stateText && stateText !== "Pending") segments.push(stateText)
    if (message) segments.push(message)
    if (at !== "-") segments.push(at)
    return segments.join(" | ")
  }

  resolveLlmCardState({ status, workflowStatus, hasComment, generatedComment }) {
    const normalizedStatus = String(workflowStatus || status || "").toLowerCase()
    const commentPresent = Boolean(hasComment || generatedComment)
    if (normalizedStatus === "failed" || normalizedStatus === "error") {
      return { code: "failed", label: "Failed", chipClass: "failed", buttonLabel: "Generate", inFlight: false }
    }
    if (normalizedStatus === "queued") {
      return { code: "queued", label: "Queued", chipClass: "queued", buttonLabel: "Queued", inFlight: true }
    }
    if (normalizedStatus === "processing" || normalizedStatus === "running" || normalizedStatus === "started") {
      return { code: "in_progress", label: "In Progress", chipClass: "in-progress", buttonLabel: "In Progress", inFlight: true }
    }
    if (normalizedStatus === "partial") {
      return { code: "partial", label: "Partial", chipClass: "in-progress", buttonLabel: "Regenerate", inFlight: false }
    }
    if (commentPresent || normalizedStatus === "completed") {
      return { code: "completed", label: "Completed", chipClass: "completed", buttonLabel: "Regenerate", inFlight: false }
    }
    if (normalizedStatus === "skipped") {
      return { code: "skipped", label: "Skipped", chipClass: "skipped", buttonLabel: "Generate", inFlight: false }
    }
    return { code: "not_started", label: "Ready", chipClass: "idle", buttonLabel: "Generate", inFlight: false }
  }

  formatDurationMs(value) {
    const ms = Number(value)
    if (!Number.isFinite(ms) || ms < 0) return "-"
    if (ms < 1000) return `${Math.round(ms)}ms`
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`
    return `${(ms / 60_000).toFixed(1)}m`
  }

  formatBytes(value) {
    const bytes = Number(value)
    if (!Number.isFinite(bytes) || bytes <= 0) return "-"
    if (bytes < 1024) return `${bytes} B`
    const kb = bytes / 1024
    if (kb < 1024) return `${kb.toFixed(1)} KB`
    return `${(kb / 1024).toFixed(1)} MB`
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

  coerceBoolean(value) {
    if (typeof value === "boolean") return value
    const normalized = String(value || "").toLowerCase().trim()
    if (["1", "true", "yes", "on"].includes(normalized)) return true
    if (["0", "false", "no", "off"].includes(normalized)) return false
    if (normalized === "") return null
    return Boolean(value)
  }

  escapeSelector(value) {
    if (typeof window.CSS !== "undefined" && typeof window.CSS.escape === "function") {
      return window.CSS.escape(String(value))
    }
    return String(value).replaceAll('"', '\\"')
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
