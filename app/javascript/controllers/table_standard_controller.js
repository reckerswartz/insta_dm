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
    autoResetEmpty: { type: Boolean, default: false },
  }

  connect() {
    this._autoResetAttempts = 0
    this._autoResetTimers = []
    this.mountTabulator()
  }

  disconnect() {
    this._autoResetTimers.forEach((timerId) => window.clearTimeout(timerId))
    this._autoResetTimers = []
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
    const storageKey = this.storageKeyValue || null

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
      paginationButtonCount: 7,
      paginationCounter: "rows",
      movableColumns: true,
      resizableColumnFit: true,
      renderHorizontal: "basic",
      renderVerticalBuffer: 360,
      headerFilterLiveFilterDelay: 550,
      layoutColumnsOnNewData: false,
      ...(storageKey ? {
        persistenceMode: "local",
        persistenceID: storageKey,
        persistence: {
          sort: true,
          filter: true,
          headerFilter: true,
          page: { page: true, size: true },
          columns: ["width", "visible"],
        },
      } : {}),
      columnDefaults: {
        vertAlign: "middle",
      },
    }

    this.tableInstance = new Tabulator(host, options)
    const attemptAutoReset = () => this.autoResetIfPersistedStateHidesRows(parsed.rows)
    this.tableInstance.on("tableBuilt", attemptAutoReset)
    this.tableInstance.on("dataProcessed", attemptAutoReset)
    attachTabulatorBehaviors(this, this.tableInstance, {
      storageKey,
      paginationSize: this.paginationSizeValue,
    })

    // Some persisted states can hide all rows before `tableBuilt` listeners run.
    queueMicrotask(attemptAutoReset)
    this._autoResetTimers.push(window.setTimeout(attemptAutoReset, 0))
    this._autoResetTimers.push(window.setTimeout(attemptAutoReset, 120))

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
        download: !isActionCol,
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

  autoResetIfPersistedStateHidesRows(sourceRows) {
    if (!this.autoResetEmptyValue) return
    const rows = Array.isArray(sourceRows) ? sourceRows : []
    if (rows.length === 0) return
    if (!this.tableInstance) return
    if (!this.tableInstance.element?.isConnected) return
    if ((this._autoResetAttempts || 0) >= 3) return

    let activeCount = 0
    let displayCount = 0
    let hasVisibleColumns = true
    try {
      activeCount = Number(this.tableInstance.getDataCount("active") || 0)
    } catch (_error) {
      activeCount = 0
    }
    try {
      displayCount = Number(this.tableInstance.getDataCount("display") || 0)
    } catch (_error) {
      displayCount = 0
    }
    try {
      const columns = this.tableInstance.getColumns?.() || []
      if (columns.length > 0) {
        hasVisibleColumns = columns.some((column) => {
          if (typeof column?.isVisible === "function") return column.isVisible()
          return true
        })
      }
    } catch (_error) {
      hasVisibleColumns = true
    }

    const needsReset = activeCount === 0 || displayCount === 0 || hasVisibleColumns === false
    if (!needsReset) return

    this._autoResetAttempts = (this._autoResetAttempts || 0) + 1
    try {
      this.tableInstance.clearHeaderFilter?.()
      this.tableInstance.clearFilter?.(true)
      this.tableInstance.clearSort?.()
      if (this.paginationValue) this.tableInstance.setPage?.(1)
      this.tableInstance.getColumns?.().forEach((column) => column?.show?.())
      // Avoid async reload during teardown; it can race with destroy in Turbo navigation.
      this.tableInstance.redraw?.(true)
    } catch (_error) {
      // Keep original rendered state if reset fails.
    }
  }
}
