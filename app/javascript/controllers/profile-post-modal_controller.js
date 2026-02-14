import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "title", "image", "caption", "stats", "comments", "meta", "generation", "download", "permalink", "suggestions"]

  open(event) {
    event.preventDefault()
    const data = event.currentTarget.dataset
    this.forwardUrl = data.forwardUrl || ""

    this.titleTarget.textContent = data.shortcode || "Post"
    this.captionTarget.textContent = data.caption || "-"
    this.statsTarget.textContent = `Likes: ${data.likes || 0} | Comments: ${data.commentsCount || 0} | Taken: ${data.takenAt || "-"}`
    this.metaTarget.textContent = `Provider: ${data.aiProvider || "-"} | Model: ${data.aiModel || "-"} | AI status: ${data.aiStatus || "pending"}`
    const fallback = String(data.commentGenFallback || "").toLowerCase() === "true"
    const status = data.commentGenStatus || "unknown"
    const source = data.commentGenSource || "unknown"
    const err = data.commentGenError || ""
    this.generationTarget.textContent = fallback ?
      `Comment generation: fallback (${status})${err ? ` | Error: ${err}` : ""}` :
      `Comment generation: ${source} (${status})`

    if (data.imageUrl) {
      this.imageTarget.src = data.imageUrl
      this.imageTarget.style.display = "block"
    } else {
      this.imageTarget.removeAttribute("src")
      this.imageTarget.style.display = "none"
    }

    this.downloadTarget.href = data.downloadUrl || "#"
    this.permalinkTarget.href = data.permalink || "#"

    this.commentsTarget.innerHTML = this._listHtml(this._safeJson(data.commentsJson), "No comments captured")
    this.suggestionsTarget.innerHTML = this._suggestionsHtml(this._safeJson(data.suggestionsJson))
    this._bindSuggestionActions()

    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  _safeJson(raw) {
    try {
      const parsed = JSON.parse(raw || "[]")
      return Array.isArray(parsed) ? parsed : []
    } catch (_) {
      return []
    }
  }

  _listHtml(items, emptyText) {
    if (!items.length) return `<p class='meta'>${emptyText}</p>`
    return `<ul class='issue-list'>${items.map((v) => `<li>${this._escape(String(v))}</li>`).join("")}</ul>`
  }

  _suggestionsHtml(items) {
    if (!items.length) return `<p class='meta'>No AI suggestions yet</p>`

    return `<ul class='issue-list'>${items.map((v, i) => {
      const txt = this._escape(String(v))
      return `<li><div>${txt}</div><div style="margin-top:6px;"><button type="button" class="btn small" data-forward-comment="${txt}" data-forward-idx="${i}">Forward Comment</button></div></li>`
    }).join("")}</ul>`
  }

  _bindSuggestionActions() {
    this.suggestionsTarget.querySelectorAll("button[data-forward-comment]").forEach((btn) => {
      btn.addEventListener("click", async (event) => {
        event.preventDefault()
        const comment = event.currentTarget.dataset.forwardComment || ""
        if (!comment || !this.forwardUrl) return

        event.currentTarget.disabled = true
        const csrf = document.querySelector('meta[name="csrf-token"]')?.content || ""
        const body = new URLSearchParams({ comment })

        try {
          const response = await fetch(this.forwardUrl, {
            method: "POST",
            headers: {
              "Accept": "text/vnd.turbo-stream.html",
              "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
              "X-CSRF-Token": csrf
            },
            body
          })
          const text = await response.text()
          if (window.Turbo && typeof window.Turbo.renderStreamMessage === "function") {
            window.Turbo.renderStreamMessage(text)
          }
        } finally {
          event.currentTarget.disabled = false
        }
      })
    })
  }

  _escape(s) {
    return String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;")
  }
}
