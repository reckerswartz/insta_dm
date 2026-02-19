import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "status"]

  static values = {
    url: String,
    pollIntervalMs: { type: Number, default: 15000 },
  }

  connect() {
    this.loading = false
    this.abortController = null
    this.pollTimer = window.setInterval(() => this.refresh(), this.pollIntervalMsValue)
    this.refresh()
  }

  disconnect() {
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }

    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  refresh(event) {
    if (event) event.preventDefault()
    if (this.loading || !this.hasUrlValue || !this.hasContentTarget) return

    this.loading = true
    this.renderStatus("Refreshing queue…")

    if (this.abortController) this.abortController.abort()
    this.abortController = new AbortController()

    fetch(this.urlValue, {
      method: "GET",
      headers: {
        Accept: "text/html",
        "X-Requested-With": "XMLHttpRequest",
      },
      signal: this.abortController.signal,
      credentials: "same-origin",
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Queue refresh failed (${response.status})`)
        }
        return response.text()
      })
      .then((html) => {
        this.contentTarget.innerHTML = html
        this.renderStatus(`Updated ${new Date().toLocaleTimeString()}`)
      })
      .catch((error) => {
        if (error.name === "AbortError") return
        this.renderStatus(error.message || "Unable to refresh queue")
      })
      .finally(() => {
        this.loading = false
      })
  }

  renderStatus(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = String(message || "")
    this.statusTarget.hidden = this.statusTarget.textContent.length === 0
  }
}
