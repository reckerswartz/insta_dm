import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"
import {
  adaptiveTableHeight,
  attachTabulatorBehaviors,
  registerCleanup,
  runTableCleanups,
} from "../lib/tabulator_helpers"

const DEFAULT_PAGE_SIZES = [10, 25, 50, 100, 200]

export default class extends Controller {
  static targets = ["table"]

  static values = {
    storageKey: String,
    paginationSize: { type: Number, default: 25 },
    pagination: { type: Boolean, default: true },
  }

  connect() {
    this.mountTabulator()
  }

  disconnect() {
    runTableCleanups(this)
    if (this.tableInstance) {
      this.tableInstance.destroy()
      this.tableInstance = null
    }
  }

  mountTabulator() {
    const table = this.hasTableTarget ? this.tableTarget : this.element.querySelector("table")
    if (!table || table.dataset.tabulatorized === "1") return

    const parsed = this.parseTable(table)
    if (!parsed.columns.length) return

    const host = document.createElement("div")
    host.className = "tabulator-host"
    table.parentNode.insertBefore(host, table)

    this._tableHeight = () => adaptiveTableHeight(host, { min: 300, max: 780, bottomPadding: 36 })

    const options = {
      layout: "fitDataStretch",
      responsiveLayout: "collapse",
      responsiveLayoutCollapseStartOpen: false,
      placeholder: "No rows available",
      data: parsed.rows,
      columns: parsed.columns,
      height: this._tableHeight(),
      pagination: this.paginationValue,
      paginationSize: this.paginationSizeValue,
      paginationSizeSelector: [...DEFAULT_PAGE_SIZES],
      paginationCounter: "rows",
      movableColumns: true,
      resizableColumnFit: true,
      renderHorizontal: "virtual",
      renderVerticalBuffer: 500,
      columnDefaults: {
        vertAlign: "middle",
      },
    }

    this.tableInstance = new Tabulator(host, options)
    attachTabulatorBehaviors(this, this.tableInstance, {
      storageKey: this.storageKeyValue || null,
      paginationSize: this.paginationSizeValue,
    })

    registerCleanup(this, () => {
      host.remove()
      table.hidden = false
      table.style.display = ""
      table.dataset.tabulatorized = "0"
    })

    table.hidden = true
    table.style.display = "none"
    table.dataset.tabulatorized = "1"
  }

  parseTable(table) {
    const headers = Array.from(table.querySelectorAll("thead th"))
    const columns = headers.map((header, idx) => {
      const title = (header.textContent || "").trim() || `Column ${idx + 1}`
      const field = `c${idx}`
      const lower = title.toLowerCase()
      const isActionCol = lower.includes("action") || lower.includes("details") || lower.includes("media")
      const widthHint = Math.max(120, Math.min(420, title.length * 14 + 90))

      return {
        title,
        field,
        minWidth: widthHint,
        sorter: "string",
        headerFilter: isActionCol ? false : "input",
        headerFilterLiveFilter: true,
        formatter: (cell) => cell.getValue(),
      }
    })

    const bodyRows = Array.from(table.querySelectorAll("tbody tr"))
    const rows = bodyRows.map((row, rowIndex) => {
      const cells = Array.from(row.querySelectorAll("td"))
      const payload = { _row_index: rowIndex }
      columns.forEach((col, idx) => {
        payload[col.field] = cells[idx]?.innerHTML || ""
      })
      return payload
    })

    return { columns, rows }
  }
}
