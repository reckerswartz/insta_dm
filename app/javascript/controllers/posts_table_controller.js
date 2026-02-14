import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.tableEl = this.element.querySelector("[data-posts-table-target='table']")
    if (!this.tableEl) return

    this.table = new Tabulator(this.tableEl, {
      layout: "fitColumns",
      height: this._tableHeight(),
      placeholder: "No posts found",

      ajaxURL: this.urlValue,
      ajaxConfig: "GET",
      ajaxContentType: "json",
      ajaxResponse: (url, params, response) => response,

      pagination: true,
      paginationMode: "remote",
      paginationSize: 50,
      paginationSizeSelector: [25, 50, 100, 200],

      sortMode: "remote",
      filterMode: "remote",
      initialSort: [{ column: "detected_at", dir: "desc" }],

      columns: [
        { title: "Detected", field: "detected_at", headerSort: true, width: 200, formatter: (c) => (c.getValue() ? new Date(c.getValue()).toLocaleString() : "-") },
        { title: "Author", field: "author_username", headerSort: true, headerFilter: "input", widthGrow: 2 },
        { title: "Kind", field: "post_kind", headerSort: true, headerFilter: "list", headerFilterParams: { values: { "": "Any", post: "post", reel: "reel", unknown: "unknown" } }, width: 90 },
        { title: "Status", field: "status", headerSort: true, headerFilter: "list", headerFilterParams: { values: { "": "Any", pending: "pending", analyzed: "analyzed", ignored: "ignored", failed: "failed" } }, width: 110 },
        { title: "Relevant", field: "relevant", headerSort: false, width: 90, formatter: (c) => (c.getValue() === true ? "<span class='yes'>Yes</span>" : c.getValue() === false ? "<span class='no'>No</span>" : "<span class='muted'>?</span>") },
        { title: "Type", field: "author_type", headerSort: false, width: 140, formatter: (c) => this._escape(c.getValue() || "") },
        { title: "Media", field: "media_attached", headerSort: false, width: 90, formatter: (c) => (c.getValue() ? "Yes" : "No") },
        {
          title: "Actions",
          field: "id",
          headerSort: false,
          widthGrow: 2,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            return `
              <div class="table-actions">
                <a class="btn small" href="${row.open_url}">Open</a>
                <a class="btn small secondary" target="_blank" rel="noreferrer" href="${this._escape(row.permalink)}">IG</a>
              </div>
            `
          },
        },
      ],

      ajaxURLGenerator: (url, config, params) => this._urlWithParams(url, params),
    })
  }

  _tableHeight() {
    const h = window.innerHeight || 900
    const target = h - 310
    return `${Math.max(340, Math.min(600, target))}px`
  }

  _urlWithParams(baseUrl, params) {
    const u = new URL(baseUrl, window.location.origin)
    Object.entries(params || {}).forEach(([k, v]) => {
      if (v === null || typeof v === "undefined") return
      const s = (typeof v === "object") ? JSON.stringify(v) : String(v)
      if (s.length === 0) return
      u.searchParams.set(k, s)
    })
    return u.toString()
  }

  _escape(s) {
    return String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;")
  }
}
