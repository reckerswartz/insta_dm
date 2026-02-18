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
    this.tableEl = this.element.querySelector("[data-profile-events-table-target='table']")
    if (!this.tableEl) return

    const options = tabulatorBaseOptions({
      url: this.urlValue,
      placeholder: "No events found",
      height: this._tableHeight(),
      initialSort: [{ column: "detected_at", dir: "desc" }],
      storageKey: "profile-events-table",
      columns: [
        {
          title: "Kind",
          field: "kind",
          headerSort: true,
          headerFilter: "input",
          minWidth: 190,
          width: 220,
          formatter: (cell) => `<code>${escapeHtml(cell.getValue() || "")}</code>`,
        },
        {
          title: "Occurred",
          field: "occurred_at",
          headerSort: true,
          minWidth: 210,
          width: 225,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        {
          title: "Detected",
          field: "detected_at",
          headerSort: true,
          minWidth: 210,
          width: 225,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        {
          title: "Details",
          field: "metadata_json",
          headerSort: false,
          minWidth: 520,
          width: 620,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "")}</span>`,
        },
        {
          title: "Media",
          field: "media_download_url",
          headerSort: false,
          hozAlign: "center",
          minWidth: 140,
          width: 150,
          formatter: (cell) => {
            const url = cell.getValue()
            if (!url) return "-"
            return `<a class="btn small secondary" href="${escapeHtml(url)}">Download</a>`
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "profile-events-table", paginationSize: 50 })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 340, max: 760, bottomPadding: 38 })
  }
}
