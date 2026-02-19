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

const ICONS = {
  open: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M12 5c-6.6 0-10 6.2-10 7s3.4 7 10 7 10-6.2 10-7-3.4-7-10-7Zm0 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm0-2.3a2.7 2.7 0 1 0 0-5.4 2.7 2.7 0 0 0 0 5.4Z"/>
    </svg>
  `,
  instagram: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M7 2h10a5 5 0 0 1 5 5v10a5 5 0 0 1-5 5H7a5 5 0 0 1-5-5V7a5 5 0 0 1 5-5Zm0 2a3 3 0 0 0-3 3v10a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3V7a3 3 0 0 0-3-3H7Zm5 3.25A4.75 4.75 0 1 1 7.25 12 4.76 4.76 0 0 1 12 7.25Zm0 2A2.75 2.75 0 1 0 14.75 12 2.75 2.75 0 0 0 12 9.25ZM17.5 6.5a1.25 1.25 0 1 1-1.25 1.25A1.25 1.25 0 0 1 17.5 6.5Z"/>
    </svg>
  `,
}

export default class extends Controller {
  static values = { url: String, accountId: Number }

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
          minWidth: 120,
          width: 130,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            return `
              <div class="table-actions no-wrap">
                <a class="btn small icon-only" href="${row.open_url}" title="Open post details" aria-label="Open post details">${ICONS.open}</a>
                <a class="btn small secondary icon-only" target="_blank" rel="noreferrer" href="${escapeHtml(row.permalink)}" title="Open on Instagram" aria-label="Open on Instagram">${ICONS.instagram}</a>
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "posts-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      topics: ["posts_table_changed"],
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

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 360, max: 900, bottomPadding: 38 })
  }
}
