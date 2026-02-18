import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"
import {
  attachTabulatorBehaviors,
  adaptiveTableHeight,
  escapeHtml,
  runTableCleanups,
  subscribeToOperationsTopics,
  tabulatorBaseOptions,
} from "../lib/tabulator_helpers"

export default class extends Controller {
  static values = {
    url: String,
    accountId: Number,
  }

  connect() {
    this.tableEl = this.element.querySelector("[data-storage-ingestions-table-target='table']")

    if (!this.tableEl) return

    const options = tabulatorBaseOptions({
      url: this.urlValue,
      placeholder: "No storage ingestions recorded",
      height: this._tableHeight(),
      initialSort: [{ column: "created_at", dir: "desc" }],
      storageKey: "storage-ingestions-table",
      columns: [
        {
          title: "When",
          field: "created_at",
          headerSort: true,
          minWidth: 210,
          width: 225,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        {
          title: "Attachment",
          field: "attachment_name",
          headerSort: true,
          headerFilter: "input",
          minWidth: 320,
          width: 360,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            return `<code>${escapeHtml(cell.getValue() || "")}</code> · ${escapeHtml(row.blob_filename || "")}`
          },
        },
        {
          title: "Record",
          field: "record_type",
          headerSort: true,
          headerFilter: "input",
          minWidth: 230,
          width: 280,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const label = `${row.record_type || "-"}#${row.record_id || "-"}`
            if (!row.record_url) return escapeHtml(label)
            return `<a href="${escapeHtml(row.record_url)}">${escapeHtml(label)}</a>`
          },
        },
        {
          title: "Content Type",
          field: "blob_content_type",
          headerSort: false,
          minWidth: 170,
          width: 210,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "-")}</span>`,
        },
        {
          title: "Size",
          field: "blob_byte_size",
          headerSort: true,
          minWidth: 130,
          width: 140,
          hozAlign: "right",
          formatter: (cell) => this._humanBytes(cell.getValue()),
        },
        {
          title: "Job",
          field: "created_by_job_class",
          headerSort: false,
          headerFilter: "input",
          minWidth: 230,
          width: 280,
          formatter: (cell) => `<code>${escapeHtml(cell.getValue() || "manual/request")}</code>`,
        },
        {
          title: "Queue",
          field: "queue_name",
          headerSort: false,
          minWidth: 150,
          width: 170,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "-")}</span>`,
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
                ${row.blob_url ? `<a class="btn small secondary" href="${escapeHtml(row.blob_url)}">Download</a>` : ""}
                ${row.record_url ? `<a class="btn small" href="${escapeHtml(row.record_url)}">Record</a>` : ""}
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "storage-ingestions-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      topics: ["storage_ingestions_changed"],
      onRefresh: () => this.table?.replaceData(),
    })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }
  }

  _humanBytes(value) {
    const bytes = Number(value) || 0
    if (bytes === 0) return "0 B"

    const units = ["B", "KB", "MB", "GB", "TB"]
    const exp = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
    const size = bytes / Math.pow(1024, exp)
    return `${size.toFixed(size >= 10 || exp === 0 ? 0 : 1)} ${units[exp]}`
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 380, max: 920, bottomPadding: 38 })
  }
}
