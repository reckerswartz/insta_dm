import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"
import {
  attachTabulatorBehaviors,
  adaptiveTableHeight,
  escapeHtml,
  runTableCleanups,
  tabulatorBaseOptions,
} from "../lib/tabulator_helpers"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.tableEl = this.element.querySelector("[data-posts-table-target='table']")
    if (!this.tableEl) return

    const options = tabulatorBaseOptions({
      url: this.urlValue,
      placeholder: "No posts found",
      height: this._tableHeight(),
      initialSort: [{ column: "detected_at", dir: "desc" }],
      storageKey: "posts-table",
      columns: [
        {
          title: "Detected",
          field: "detected_at",
          headerSort: true,
          minWidth: 210,
          width: 220,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        { title: "Author", field: "author_username", headerSort: true, headerFilter: "input", minWidth: 220, width: 250 },
        {
          title: "Kind",
          field: "post_kind",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", post: "post", reel: "reel", unknown: "unknown" } },
          minWidth: 110,
          width: 120,
        },
        {
          title: "Status",
          field: "status",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", pending: "pending", analyzed: "analyzed", ignored: "ignored", failed: "failed" } },
          minWidth: 120,
          width: 130,
        },
        {
          title: "Relevant",
          field: "relevant",
          headerSort: false,
          minWidth: 100,
          width: 110,
          formatter: (cell) => {
            const value = cell.getValue()
            if (value === true) return "<span class='yes'>Yes</span>"
            if (value === false) return "<span class='no'>No</span>"
            return "<span class='muted'>?</span>"
          },
        },
        {
          title: "Type",
          field: "author_type",
          headerSort: false,
          minWidth: 150,
          width: 170,
          formatter: (cell) => escapeHtml(cell.getValue() || ""),
        },
        {
          title: "Media",
          field: "media_attached",
          headerSort: false,
          minWidth: 100,
          width: 110,
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
        },
        {
          title: "Actions",
          field: "id",
          headerSort: false,
          minWidth: 230,
          width: 260,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            return `
              <div class="table-actions no-wrap">
                <a class="btn small" href="${row.open_url}">Open</a>
                <a class="btn small secondary" target="_blank" rel="noreferrer" href="${escapeHtml(row.permalink)}">IG</a>
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "posts-table", paginationSize: 50 })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 360, max: 900, bottomPadding: 38 })
  }
}
