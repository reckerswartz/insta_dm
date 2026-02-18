import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static values = { accountId: Number }

  connect() {
    this.consumer = null
    this.subscription = null
    this.wsConnected = false
    this.pendingEventIds = new Set()
    this.ensureSubscription()
  }

  disconnect() {
    if (this.consumer && this.subscription) {
      this.consumer.subscriptions.remove(this.subscription)
    }
    this.pendingEventIds.clear()
    this.wsConnected = false
  }

  async generateComment(event) {
    event.preventDefault()
    const button = event.currentTarget
    const eventId = button?.dataset?.eventId || button?.closest("[data-event-id]")?.dataset?.eventId
    if (!eventId) return
    const key = String(eventId)
    if (this.pendingEventIds.has(key)) return

    try {
      this.ensureSubscription()
      this.pendingEventIds.add(key)
      this.updateButtonState(button, { disabled: true, label: "Queued...", loading: true, eta: null })
      const result = await this.callGenerateCommentApi(eventId)
      this.processImmediateResult(eventId, result)
    } catch (error) {
      this.pendingEventIds.delete(key)
      this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate Comment Locally", loading: false, eta: null })
      this.showNotification(`Failed to generate comment: ${error.message}`, "error")
    }
  }

  ensureSubscription() {
    if (!Number.isFinite(this.accountIdValue) || this.accountIdValue <= 0) return
    if (this.subscription) return

    try {
      this.consumer = createConsumer()
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
            this.showNotification("Real-time updates are unavailable. Please refresh and retry.", "error")
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

  async callGenerateCommentApi(eventId) {
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
      }),
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || `Request failed (${response.status})`)
    }

    return payload
  }

  processImmediateResult(eventId, result) {
    const status = String(result?.status || "").toLowerCase()
    if (status === "completed") {
      this.handleGenerationComplete(eventId, {
        comment: result.llm_generated_comment,
        generated_at: result.llm_comment_generated_at,
        provider: result.llm_comment_provider,
        model: result.llm_comment_model,
      })
      return
    }

    if (status === "queued") {
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "Queued...",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
      })
      return
    }

    if (status === "running" || status === "started") {
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "Generating...",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
      })
      return
    }

    this.pendingEventIds.delete(String(eventId))
  }

  handleReceived(data) {
    const eventId = String(data?.event_id || "")
    if (!eventId) return

    const status = String(data?.status || "").toLowerCase()
    switch (status) {
      case "queued":
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: "Queued...",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
        })
        break
      case "running":
      case "started":
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: data?.progress ? `Generating... ${Number(data.progress).toFixed(0)}%` : "Generating...",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
        })
        break
      case "completed":
        this.handleGenerationComplete(eventId, data)
        break
      case "skipped":
        this.pendingEventIds.delete(eventId)
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate Comment Locally", loading: false, eta: null })
        this.showNotification(data?.message || "Comment generation skipped: no usable local context.", "notice")
        break
      case "error":
      case "failed":
        this.pendingEventIds.delete(eventId)
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate Comment Locally", loading: false, eta: null })
        this.showNotification(`Failed to generate comment: ${data?.error || data?.message || "Unknown error"}`, "error")
        break
      default:
        break
    }
  }

  handleGenerationComplete(eventId, data) {
    this.pendingEventIds.delete(String(eventId))
    const storyCard = document.querySelector(`[data-event-id="${this.escapeSelector(eventId)}"]`)
    if (storyCard) {
      const commentSection = storyCard.querySelector(".llm-comment-section")
      const generatedAt = this.formatDate(data.generated_at)
      const commentText = data.comment || data.llm_generated_comment || ""

      if (commentSection && commentText) {
        commentSection.innerHTML = `
          <div class="llm-comment-section success">
            <p class="llm-generated-comment"><strong>AI Suggestion:</strong> ${this.esc(commentText)}</p>
            <p class="meta llm-comment-meta">
              Generated ${this.esc(generatedAt)}
              ${data.provider ? ` via ${this.esc(data.provider)}` : ""}
              ${data.model ? ` (${this.esc(data.model)})` : ""}
            </p>
          </div>
        `
      }
    }

    this.updateButtonsForEvent(eventId, { disabled: true, label: "Completed", loading: false, eta: null })
    this.showNotification("Comment generated successfully.", "success")
  }

  updateButtonsForEvent(eventId, state) {
    document
      .querySelectorAll(`.generate-comment-btn[data-event-id="${this.escapeSelector(String(eventId))}"]`)
      .forEach((button) => this.updateButtonState(button, state))
  }

  updateButtonState(button, { disabled, label, loading, eta = null }) {
    if (!button) return
    button.disabled = Boolean(disabled)
    button.classList.toggle("loading", Boolean(loading))
    if (typeof label === "string" && label.length > 0) {
      button.textContent = label
    }

    const container = button.closest(".llm-comment-section") || button.parentElement
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

  showNotification(message, type = "notice") {
    const container = document.getElementById("notifications")
    if (!container) return

    const notification = document.createElement("div")
    notification.className = `notification ${type}`
    notification.textContent = message
    container.appendChild(notification)

    setTimeout(() => notification.remove(), 4500)
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
