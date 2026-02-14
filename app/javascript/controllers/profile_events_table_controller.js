import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.tableEl = this.element.querySelector("[data-profile-events-table-target='table']")

    if (!this.tableEl) return

    this.table = new Tabulator(this.tableEl, {
      layout: "fitColumns",
      height: this._tableHeight(),
      placeholder: "No events found",

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
        {
          title: "Kind",
          field: "kind",
          headerSort: true,
          headerFilter: "input",
          formatter: (cell) => `<code>${this._escape(cell.getValue() || "")}</code>`,
          width: 180,
        },
        {
          title: "Occurred",
          field: "occurred_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          width: 200,
        },
        {
          title: "Detected",
          field: "detected_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          width: 200,
        },
        {
          title: "Details",
          field: "metadata_json",
          headerSort: false,
          formatter: (cell) => `<span class="meta">${this._escape(cell.getValue() || "")}</span>`,
          widthGrow: 3,
        },
        {
          title: "Media",
          field: "media_download_url",
          headerSort: false,
          hozAlign: "center",
          formatter: (cell) => {
            const url = cell.getValue()
            if (!url) return "-"
            return `<a class="btn small secondary" href="${this._escape(url)}">download</a>`
          },
          width: 120,
        },
      ],

      ajaxURLGenerator: (url, config, params) => this._urlWithParams(url, params),
    })
  }

  _tableHeight() {
    const h = window.innerHeight || 900
    const target = h - 340
    return `${Math.max(320, Math.min(540, target))}px`
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
