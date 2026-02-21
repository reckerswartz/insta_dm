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
      const result = await this.callGenerateCommentApi(eventId, { force })
      this.processImmediateResult(eventId, result)
    } catch (error) {
      this.pendingEventIds.delete(key)
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
        this.updateStatusDisplaysForEvent(eventId, { status: "skipped" })
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
        notifyApp(data?.message || "Comment generation skipped: no usable local context.", "notice")
        break
      case "error":
      case "failed":
        this.stopStatusPolling(eventId)
        this.pendingEventIds.delete(eventId)
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
    const generatedAt = data?.generated_at || data?.llm_comment_generated_at
    this.updateStatusDisplaysForEvent(eventId, { status: "completed", generatedAt })
    this.updateButtonsForEvent(eventId, { disabled: false, label: "Regenerate", loading: false, eta: null, force: true })
    notifyApp("Comment generated successfully.", "success")
  }

  updateProgressForEvent(eventId, data) {
    // Card view is summary-only; detailed stage rendering lives in the modal details flow.
    return
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

  renderStageProgress(section, stages) {
    if (!section) return
    const entries = Object.entries(stages)
    if (entries.length === 0) return
    const html = entries
      .sort((a, b) => String(a[0]).localeCompare(String(b[0])))
      .map(([, row]) => {
        const state = String(row?.state || "pending")
        const label = String(row?.label || "Stage")
        const progress = Number(row?.progress)
        const stateLabel = state === "completed" ? "Completed" : (state === "running" ? `In Progress${Number.isFinite(progress) ? ` (${Math.round(progress)}%)` : ""}` : "Pending")
        const icon = state === "completed" ? "✓" : (state === "running" ? "…" : "○")
        return `<li><span>${icon}</span> ${this.esc(label)} - ${this.esc(stateLabel)}</li>`
      })
      .join("")

    let container = section.querySelector(".llm-progress-steps")
    if (!container) {
      container = document.createElement("ul")
      container.className = "meta llm-progress-steps"
      section.appendChild(container)
    }
    container.innerHTML = html
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
