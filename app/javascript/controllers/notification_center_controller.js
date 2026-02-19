import { Controller } from "@hotwired/stimulus"

const DEFAULT_TTL_MS = 4500
const ERROR_TTL_MS = 6500

export default class extends Controller {
  static values = {
    max: { type: Number, default: 5 },
    ttlMs: { type: Number, default: DEFAULT_TTL_MS },
  }

  connect() {
    this.boundNotify = this.handleNotify.bind(this)
    document.addEventListener("app:notify", this.boundNotify)

    this.enhanceExistingChildren()
    this.installObserver()
  }

  disconnect() {
    document.removeEventListener("app:notify", this.boundNotify)
    this.observer?.disconnect()
  }

  dismiss(event) {
    event.preventDefault()
    const toast = event.currentTarget.closest("[data-notification-item]")
    if (toast) this.removeToast(toast)
  }

  handleNotify(event) {
    const detail = event?.detail || {}
    const message = String(detail.message || "").trim()
    if (!message) return

    const type = this.normalizeType(detail.type)
    const toast = this.buildToast({
      message,
      type,
      ttlMs: Number(detail.ttlMs) || this.ttlFor(type),
    })
    this.element.appendChild(toast)
    this.trimToMax()
  }

  installObserver() {
    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        mutation.addedNodes.forEach((node) => {
          if (!(node instanceof HTMLElement)) return
          this.enhanceIncomingNode(node)
        })
      })
    })
    this.observer.observe(this.element, { childList: true })
  }

  enhanceExistingChildren() {
    Array.from(this.element.children).forEach((node) => this.enhanceIncomingNode(node))
    this.trimToMax()
  }

  enhanceIncomingNode(node) {
    if (!(node instanceof HTMLElement)) return
    if (node.dataset.notificationItem === "1" || node.classList.contains("notification-toast")) {
      const type = this.typeFromElement(node)
      node.classList.add("notification-toast", type)
      node.dataset.notificationItem = "1"
      if (!node.querySelector(".notification-toast-close")) {
        const close = document.createElement("button")
        close.type = "button"
        close.className = "notification-toast-close"
        close.setAttribute("data-action", "notification-center#dismiss")
        close.setAttribute("aria-label", "Dismiss notification")
        close.textContent = "×"
        node.appendChild(close)
      }
      this.armTimeout(node, this.ttlFor(type))
      this.trimToMax()
      return
    }

    const type = this.typeFromElement(node)
    const message = node.textContent?.trim() || ""
    if (!message) {
      node.remove()
      return
    }

    const toast = this.buildToast({
      message,
      type,
      ttlMs: this.ttlFor(type),
    })
    node.replaceWith(toast)
    this.trimToMax()
  }

  typeFromElement(node) {
    const classList = Array.from(node.classList || [])
    const firstKnown = classList.find((cls) => ["notice", "success", "alert", "warning", "error"].includes(cls))
    return this.normalizeType(firstKnown || node.dataset.kind)
  }

  normalizeType(raw) {
    const value = String(raw || "").toLowerCase()
    if (value === "alert" || value === "warning") return "warning"
    if (value === "error") return "error"
    if (value === "success") return "success"
    return "notice"
  }

  ttlFor(type) {
    if (type === "error") return ERROR_TTL_MS
    return this.ttlMsValue > 0 ? this.ttlMsValue : DEFAULT_TTL_MS
  }

  buildToast({ message, type, ttlMs }) {
    const toast = document.createElement("div")
    toast.className = `notification-toast ${type}`
    toast.dataset.notificationItem = "1"
    toast.setAttribute("role", type === "error" ? "alert" : "status")
    toast.innerHTML = `
      <div class="notification-toast-body">${this.esc(message)}</div>
      <button type="button" class="notification-toast-close" data-action="notification-center#dismiss" aria-label="Dismiss notification">&times;</button>
    `

    this.armTimeout(toast, ttlMs)
    return toast
  }

  armTimeout(toast, ttlMs) {
    const existing = Number(toast.dataset.timeoutId)
    if (Number.isFinite(existing)) window.clearTimeout(existing)

    const timeout = window.setTimeout(() => this.removeToast(toast), Math.max(1200, Number(ttlMs) || DEFAULT_TTL_MS))
    toast.dataset.timeoutId = String(timeout)
  }

  removeToast(toast) {
    if (!toast || !toast.isConnected) return
    const timeoutId = Number(toast.dataset.timeoutId)
    if (Number.isFinite(timeoutId)) window.clearTimeout(timeoutId)

    toast.classList.add("is-leaving")
    window.setTimeout(() => toast.remove(), 160)
  }

  trimToMax() {
    const max = Math.max(1, this.maxValue || 5)
    const items = Array.from(this.element.querySelectorAll("[data-notification-item='1']"))
    if (items.length <= max) return

    items.slice(0, items.length - max).forEach((item) => this.removeToast(item))
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
