import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.tableEl = this.element.querySelector("[data-background-job-failures-table-target='table']")

    if (!this.tableEl) return

    this.table = new Tabulator(this.tableEl, {
      layout: "fitColumns",
      height: this._tableHeight(),
      placeholder: "No failures found",

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
      initialSort: [{ column: "occurred_at", dir: "desc" }],

      columns: [
        {
          title: "When",
          field: "occurred_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          width: 220,
        },
        {
          title: "Job",
          field: "job_class",
          headerSort: true,
          headerFilter: "input",
          formatter: (cell) => `<code>${this._escape(cell.getValue() || "")}</code>`,
          widthGrow: 2,
        },
        {
          title: "Scope",
          field: "job_scope",
          headerSort: false,
          formatter: (cell) => this._escape(cell.getValue() || "system"),
          width: 100,
        },
        {
          title: "Context",
          field: "context_label",
          headerSort: false,
          formatter: (cell) => `<span class="meta">${this._escape(cell.getValue() || "System")}</span>`,
          widthGrow: 2,
        },
        {
          title: "Queue",
          field: "queue_name",
          headerSort: true,
          headerFilter: "input",
          formatter: (cell) => this._escape(cell.getValue() || ""),
          width: 160,
        },
        {
          title: "Error",
          field: "error_message",
          headerSort: false,
          headerFilter: "input",
          formatter: (cell) => `<span class="meta">${this._escape(cell.getValue() || "")}</span>`,
          widthGrow: 3,
        },
        {
          title: "",
          field: "open_url",
          headerSort: false,
          hozAlign: "center",
          formatter: (cell) => {
            const url = cell.getValue()
            if (!url) return ""
            return `<a class="btn small secondary" href="${this._escape(url)}">open</a>`
          },
          width: 90,
        },
      ],

      ajaxURLGenerator: (url, config, params) => this._urlWithParams(url, params),
    })
  }

  _tableHeight() {
    const h = window.innerHeight || 900
    const target = h - 320
    return `${Math.max(360, Math.min(620, target))}px`
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
