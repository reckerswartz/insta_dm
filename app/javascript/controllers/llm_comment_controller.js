import { Controller } from "@hotwired/stimulus"
import { getCableConsumer } from "../lib/cable_consumer"
import { notifyApp } from "../lib/notifications"

export default class extends Controller {
  static values = { accountId: Number }

  connect() {
    this.consumer = null
    this.subscription = null
    this.wsConnected = false
    this.pendingEventIds = new Set()
    this.statusPollers = new Map()
    this.statusPollFailures = new Map()
    this.ensureSubscription()
  }

  disconnect() {
    if (this.consumer && this.subscription) {
      this.consumer.subscriptions.remove(this.subscription)
    }
    this.clearStatusPollers()
    this.pendingEventIds.clear()
    this.wsConnected = false
  }

  async generateComment(event) {
    event.preventDefault()
    const button = event.currentTarget
    const eventId = button?.dataset?.eventId || button?.closest("[data-event-id]")?.dataset?.eventId
    if (!eventId) return
    const key = String(eventId)
    const force = String(button?.dataset?.generateForce || "").toLowerCase() === "true"
    if (this.pendingEventIds.has(key)) return

    try {
      this.ensureSubscription()
      this.pendingEventIds.add(key)
      this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
      this.updateButtonsForEvent(eventId, { disabled: true, label: "Queued", loading: true, eta: null, force: false })
      this.updateProgressForEvent(eventId, { status: "queued", llm_processing_stages: this.defaultQueuedStages() })
      const result = await this.callGenerateCommentApi(eventId, { force })
      this.processImmediateResult(eventId, result)
    } catch (error) {
      this.pendingEventIds.delete(key)
      this.updateProgressForEvent(eventId, { status: "failed" })
      this.updateStatusDisplaysForEvent(eventId, { status: "failed" })
      this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
      notifyApp(`Failed to generate comment: ${error.message}`, "error")
    }
  }

  ensureSubscription() {
    if (!Number.isFinite(this.accountIdValue) || this.accountIdValue <= 0) return
    if (this.subscription) return

    try {
      this.consumer = getCableConsumer()
      this.subscription = this.consumer.subscriptions.create(
        {
          channel: "LlmCommentGenerationChannel",
          account_id: this.accountIdValue,
        },
        {
          connected: () => {
            this.wsConnected = true
          },
          disconnected: () => {
            this.wsConnected = false
          },
          rejected: () => {
            this.wsConnected = false
            notifyApp("Real-time updates are unavailable. Please refresh and retry.", "error")
          },
          received: (data) => this.handleReceived(data),
        },
      )
    } catch (error) {
      // Keep queueing available, but inform user that realtime feedback cannot be guaranteed.
      this.subscription = null
      this.consumer = null
      this.wsConnected = false
      console.warn("Failed to initialize LLM comment subscription", error)
    }
  }

  async callGenerateCommentApi(eventId, { force = false } = {}) {
    const response = await fetch(`/instagram_accounts/${this.accountIdValue}/generate_llm_comment`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCsrfToken(),
        Accept: "application/json",
      },
      body: JSON.stringify({
        event_id: eventId,
        provider: "local",
        force,
      }),
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || `Request failed (${response.status})`)
    }

    return payload
  }

  async callGenerateCommentStatusApi(eventId) {
    const response = await fetch(`/instagram_accounts/${this.accountIdValue}/generate_llm_comment`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCsrfToken(),
        Accept: "application/json",
      },
      body: JSON.stringify({
        event_id: eventId,
        provider: "local",
        status_only: true,
      }),
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || `Status request failed (${response.status})`)
    }

    return payload
  }

  processImmediateResult(eventId, result) {
    const status = String(result?.status || "").toLowerCase()
    if (status === "completed") {
      this.updateProgressForEvent(eventId, result)
      this.stopStatusPolling(eventId)
      this.handleGenerationComplete(eventId, {
        generated_at: result.llm_comment_generated_at,
      })
      return
    }

    if (status === "queued") {
      this.startStatusPolling(eventId)
      this.updateProgressForEvent(eventId, result)
      this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "Queued",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
        force: false,
      })
      return
    }

    if (status === "running" || status === "started") {
      this.startStatusPolling(eventId)
      this.updateProgressForEvent(eventId, result)
      this.updateStatusDisplaysForEvent(eventId, { status: "running" })
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "In Progress",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
        force: false,
      })
      return
    }

    if (status === "failed" || status === "error" || status === "skipped") {
      this.updateProgressForEvent(eventId, result)
      this.stopStatusPolling(eventId)
      this.pendingEventIds.delete(String(eventId))
      this.updateStatusDisplaysForEvent(eventId, { status })
      this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
      return
    }

    this.stopStatusPolling(eventId)
    this.pendingEventIds.delete(String(eventId))
    this.updateStatusDisplaysForEvent(eventId, { status: "not_requested" })
    this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
  }

  handleReceived(data) {
    const eventId = String(data?.event_id || "")
    if (!eventId) return

    const status = String(data?.status || "").toLowerCase()
    switch (status) {
      case "queued":
        this.startStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: "Queued",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
          force: false,
        })
        break
      case "running":
      case "started":
        this.startStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "running" })
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: "In Progress",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
          force: false,
        })
        break
      case "completed":
        this.stopStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.handleGenerationComplete(eventId, data)
        break
      case "skipped":
        this.stopStatusPolling(eventId)
        this.pendingEventIds.delete(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "skipped" })
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
        notifyApp(data?.message || "Comment generation skipped: no usable local context.", "notice")
        break
      case "error":
      case "failed":
        this.stopStatusPolling(eventId)
        this.pendingEventIds.delete(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "failed" })
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
        notifyApp(`Failed to generate comment: ${data?.error || data?.message || "Unknown error"}`, "error")
        break
      default:
        break
    }
  }

  handleGenerationComplete(eventId, data) {
    this.stopStatusPolling(eventId)
    this.pendingEventIds.delete(String(eventId))
    this.updateProgressForEvent(eventId, data)
    const generatedAt = data?.generated_at || data?.llm_comment_generated_at
    this.updateStatusDisplaysForEvent(eventId, { status: "completed", generatedAt })
    this.updateButtonsForEvent(eventId, { disabled: false, label: "Regenerate", loading: false, eta: null, force: true })
    notifyApp("Comment generated successfully.", "success")
  }

  updateProgressForEvent(eventId, data) {
    const key = String(eventId || "").trim()
    if (!key) return

    const status = String(data?.status || "").toLowerCase()
    const stageMap = this.extractStageMap(data)
    let entries = this.normalizeStageEntries(stageMap)
    if (entries.length === 0 && ["queued", "running", "started"].includes(status)) {
      entries = this.normalizeStageEntries(this.defaultQueuedStages())
    }
    const lastStage = this.extractLastStage(data)

    this.findProgressContainersForEvent(key).forEach((container) => {
      this.renderStageProgress(container, entries, { lastStage, status })
    })
  }

  updateStatusDisplaysForEvent(eventId, { status, generatedAt = null } = {}) {
    const state = this.resolveUiState(status)
    document
      .querySelectorAll(`.llm-comment-section[data-event-id="${this.escapeSelector(String(eventId))}"]`)
      .forEach((section) => {
        section.dataset.llmStatus = state.code

        const statusEl = section.querySelector("[data-role='llm-status']")
        if (statusEl) {
          statusEl.textContent = state.label
          statusEl.classList.remove("queued", "in-progress", "completed", "failed", "skipped", "idle")
          statusEl.classList.add(state.chipClass)
        }

        const completionEl = section.querySelector("[data-role='llm-completion']")
        if (completionEl) {
          if (state.code === "completed") {
            completionEl.classList.remove("hidden")
            completionEl.textContent = `Completed ${this.formatDate(generatedAt)}`
          } else {
            completionEl.classList.add("hidden")
          }
        }
      })
  }

  resolveUiState(status) {
    const normalizedStatus = String(status || "").toLowerCase()
    if (normalizedStatus === "completed") {
      return { code: "completed", label: "Completed", chipClass: "completed" }
    }
    if (normalizedStatus === "queued") {
      return { code: "queued", label: "Queued", chipClass: "queued" }
    }
    if (normalizedStatus === "running" || normalizedStatus === "started") {
      return { code: "in_progress", label: "In Progress", chipClass: "in-progress" }
    }
    if (normalizedStatus === "failed" || normalizedStatus === "error") {
      return { code: "failed", label: "Failed", chipClass: "failed" }
    }
    if (normalizedStatus === "skipped") {
      return { code: "skipped", label: "Skipped", chipClass: "skipped" }
    }
    return { code: "not_started", label: "Ready", chipClass: "idle" }
  }

  findProgressContainersForEvent(eventId) {
    const escaped = this.escapeSelector(String(eventId))
    const containers = new Set()

    document
      .querySelectorAll(`.llm-comment-section[data-event-id="${escaped}"]`)
      .forEach((section) => containers.add(section))

    document
      .querySelectorAll(`.story-modal .generate-comment-btn[data-event-id="${escaped}"]`)
      .forEach((button) => {
        const section = button.closest(".story-modal-section")
        if (section) containers.add(section)
      })

    return Array.from(containers)
  }

  renderStageProgress(container, entries, { lastStage = null, status = "" } = {}) {
    if (!container) return

    let panel = container.querySelector("[data-role='llm-stage-panel']")
    if (!panel) {
      panel = document.createElement("section")
      panel.className = "llm-stage-progress-panel"
      panel.dataset.role = "llm-stage-panel"
      panel.innerHTML = `
        <p class="meta llm-stage-progress-title"><strong>AI Processing Stages</strong></p>
        <ul class="meta llm-progress-steps llm-live-progress-steps" data-role="llm-stage-list"></ul>
        <p class="meta llm-stage-last hidden" data-role="llm-stage-last"></p>
      `
      container.appendChild(panel)
    }

    const activeStatus = ["queued", "running", "started", "completed", "failed", "error", "skipped"].includes(String(status))
    if (!activeStatus && entries.length === 0) {
      panel.classList.add("hidden")
      return
    }

    const list = panel.querySelector("[data-role='llm-stage-list']")
    if (list) {
      list.innerHTML = entries
        .map((entry) => {
          const visual = this.resolveStageVisual(entry.state, entry.progress)
          return `
            <li class="llm-stage-row ${this.esc(visual.className)}" data-stage-key="${this.esc(entry.key)}">
              <span class="llm-stage-icon">${this.esc(visual.icon)}</span>
              <span class="llm-stage-label">${this.esc(entry.label)}</span>
              <span class="llm-stage-state">${this.esc(visual.label)}</span>
            </li>
          `
        })
        .join("")
    }

    const lastStageEl = panel.querySelector("[data-role='llm-stage-last']")
    if (lastStageEl) {
      const lastStageText = this.formatLastStageText(lastStage)
      if (lastStageText) {
        lastStageEl.textContent = `Latest: ${lastStageText}`
        lastStageEl.classList.remove("hidden")
      } else {
        lastStageEl.textContent = ""
        lastStageEl.classList.add("hidden")
      }
    }

    panel.classList.toggle("hidden", entries.length === 0 && !lastStage)
  }

  extractStageMap(data) {
    const fromRequest = data?.llm_processing_stages && typeof data.llm_processing_stages === "object" ? data.llm_processing_stages : {}
    const fromBroadcast = data?.stage_statuses && typeof data.stage_statuses === "object" ? data.stage_statuses : {}
    return this.mergeStageMaps(fromBroadcast, fromRequest)
  }

  mergeStageMaps(primary, secondary) {
    const merged = {}
    const merge = (input) => {
      if (!input || typeof input !== "object") return
      Object.entries(input).forEach(([key, row]) => {
        if (!row || typeof row !== "object") return
        const current = merged[key] && typeof merged[key] === "object" ? merged[key] : {}
        merged[key] = { ...current, ...row }
      })
    }
    merge(primary)
    merge(secondary)
    return merged
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
          label: label || "Stage",
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
      video_analysis: 12,
      audio_extraction: 14,
      speech_transcription: 16,
      ocr_analysis: 20,
      vision_detection: 24,
      face_recognition: 28,
      metadata_extraction: 32,
      context_matching: 40,
      prompt_construction: 50,
      llm_generation: 60,
      relevance_scoring: 70,
    }
    return Number(order[String(stageKey)] || 900)
  }

  resolveStageVisual(state, progress) {
    const normalized = String(state || "pending").toLowerCase()
    if (normalized === "completed") {
      return { className: "stage-completed", label: "Completed", icon: "done" }
    }
    if (normalized === "completed_with_warnings") {
      return { className: "stage-warning", label: "Completed (Warnings)", icon: "warn" }
    }
    if (normalized === "running" || normalized === "started") {
      const suffix = Number.isFinite(progress) ? ` (${Math.round(progress)}%)` : ""
      return { className: "stage-running", label: `In Progress${suffix}`, icon: "run" }
    }
    if (normalized === "queued") {
      return { className: "stage-queued", label: "Queued", icon: "queue" }
    }
    if (normalized === "failed" || normalized === "error") {
      return { className: "stage-failed", label: "Failed", icon: "fail" }
    }
    if (normalized === "skipped") {
      return { className: "stage-skipped", label: "Skipped", icon: "skip" }
    }
    return { className: "stage-pending", label: "Pending", icon: "wait" }
  }

  extractLastStage(data) {
    const explicit = data?.llm_last_stage
    if (explicit && typeof explicit === "object") return explicit

    if (String(data?.stage || "").trim().length > 0 || String(data?.message || "").trim().length > 0) {
      return {
        stage: data?.stage,
        state: data?.status,
        message: data?.message,
        at: data?.at || data?.updated_at || null,
      }
    }

    return null
  }

  formatLastStageText(row) {
    if (!row || typeof row !== "object") return ""
    const stage = String(row?.stage || row?.label || "").trim()
    const state = String(row?.state || "").trim().toLowerCase()
    const message = String(row?.message || "").trim()
    const timeValue = row?.at || row?.updated_at || null

    const stageText = stage ? this.humanizeStageKey(stage) : ""
    const stateText = this.resolveStageVisual(state).label
    const at = this.formatDate(timeValue)
    const segments = []
    if (stageText) segments.push(stageText)
    if (stateText && stateText !== "Pending") segments.push(stateText)
    if (message) segments.push(message)
    if (at !== "-") segments.push(at)
    return segments.join(" | ")
  }

  defaultQueuedStages() {
    return {
      queue_wait: { label: "Queue Wait", state: "queued", progress: 0, order: 5 },
      ocr_analysis: { label: "OCR Analysis", state: "pending", progress: 0, order: 20 },
      vision_detection: { label: "Video/Image Analysis", state: "pending", progress: 0, order: 24 },
      face_recognition: { label: "Face Recognition", state: "pending", progress: 0, order: 28 },
      metadata_extraction: { label: "Metadata Extraction", state: "pending", progress: 0, order: 32 },
      context_matching: { label: "Context Matching", state: "pending", progress: 0, order: 40 },
      prompt_construction: { label: "Prompt Construction", state: "pending", progress: 0, order: 50 },
      llm_generation: { label: "Comment Generation", state: "pending", progress: 0, order: 60 },
      relevance_scoring: { label: "Relevance Scoring", state: "pending", progress: 0, order: 70 },
    }
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

  startStatusPolling(eventId) {
    const key = String(eventId)
    if (this.statusPollers.has(key)) return

    const timer = window.setInterval(async () => {
      try {
        const result = await this.callGenerateCommentStatusApi(key)
        this.statusPollFailures.set(key, 0)
        this.processImmediateResult(key, result)
      } catch (error) {
        const failures = Number(this.statusPollFailures.get(key) || 0) + 1
        this.statusPollFailures.set(key, failures)
        if (failures >= 4) {
          this.stopStatusPolling(key)
          notifyApp("Unable to verify comment generation status. Please refresh the archive.", "error")
        }
      }
    }, 3000)

    this.statusPollers.set(key, timer)
  }

  stopStatusPolling(eventId) {
    const key = String(eventId)
    const timer = this.statusPollers.get(key)
    if (timer) {
      clearInterval(timer)
      this.statusPollers.delete(key)
    }
    this.statusPollFailures.delete(key)
  }

  clearStatusPollers() {
    this.statusPollers.forEach((timer) => clearInterval(timer))
    this.statusPollers.clear()
    this.statusPollFailures.clear()
  }

  updateButtonsForEvent(eventId, state) {
    document
      .querySelectorAll(`.generate-comment-btn[data-event-id="${this.escapeSelector(String(eventId))}"]`)
      .forEach((button) => this.updateButtonState(button, state))
  }

  updateButtonState(button, { disabled, label, loading, eta = null, force = null }) {
    if (!button) return
    button.disabled = Boolean(disabled)
    button.classList.toggle("loading", Boolean(loading))
    if (typeof label === "string" && label.length > 0) {
      button.textContent = label
    }
    if (typeof force === "boolean") {
      button.dataset.generateForce = force ? "true" : "false"
    }

    const container = button.closest(".llm-comment-section, .story-modal-section") || button.parentElement
    if (!container) return
    const existing = container.querySelector(".llm-progress-hint")
    if (eta) {
      if (existing) {
        existing.textContent = eta
      } else {
        const hint = document.createElement("p")
        hint.className = "meta llm-progress-hint"
        hint.textContent = eta
        container.appendChild(hint)
      }
    } else if (existing) {
      existing.remove()
    }
  }

  buildEtaText(seconds, queueSize) {
    const sec = Number(seconds)
    if (!Number.isFinite(sec) || sec <= 0) return null
    const rangeLow = Math.max(5, Math.floor(sec * 0.7))
    const rangeHigh = Math.ceil(sec * 1.5)
    const queue = Number.isFinite(Number(queueSize)) ? ` (queue: ${Number(queueSize)})` : ""
    return `Estimated ${rangeLow}-${rangeHigh}s${queue}`
  }

  formatDate(value) {
    if (!value) return "-"
    const date = new Date(value)
    return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString()
  }

  getCsrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
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
