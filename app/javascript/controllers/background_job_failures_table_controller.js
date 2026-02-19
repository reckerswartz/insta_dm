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
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.content || ""
    this.tableEl = this.element.querySelector("[data-background-job-failures-table-target='table']")

    if (!this.tableEl) return

    const options = tabulatorBaseOptions({
      url: this.urlValue,
      placeholder: "No failures found",
      height: this._tableHeight(),
      initialSort: [{ column: "occurred_at", dir: "desc" }],
      storageKey: "background-job-failures-table",
      columns: [
        {
          title: "When",
          field: "occurred_at",
          headerSort: true,
          minWidth: 220,
          width: 230,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        {
          title: "Job",
          field: "job_class",
          headerSort: true,
          headerFilter: "input",
          minWidth: 250,
          width: 280,
          formatter: (cell) => `<code>${escapeHtml(cell.getValue() || "")}</code>`,
        },
        {
          title: "Scope",
          field: "job_scope",
          headerSort: false,
          minWidth: 110,
          width: 120,
          formatter: (cell) => `<span class="pill">${escapeHtml(cell.getValue() || "system")}</span>`,
        },
        {
          title: "Context",
          field: "context_label",
          headerSort: false,
          minWidth: 200,
          width: 260,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "System")}</span>`,
        },
        {
          title: "Queue",
          field: "queue_name",
          headerSort: true,
          headerFilter: "input",
          minWidth: 170,
          width: 180,
          formatter: (cell) => escapeHtml(cell.getValue() || ""),
        },
        {
          title: "Kind",
          field: "failure_kind",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: {
            values: {
              "": "Any",
              authentication: "authentication",
              transient: "transient",
              runtime: "runtime",
            },
          },
          minWidth: 150,
          width: 170,
          formatter: (cell) => `<span class="pill">${escapeHtml(cell.getValue() || "runtime")}</span>`,
        },
        {
          title: "Retryable",
          field: "retryable",
          headerSort: false,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          minWidth: 110,
          width: 120,
          formatter: (cell) => (cell.getValue() ? "<span class='yes'>Yes</span>" : "<span class='no'>No</span>"),
        },
        {
          title: "Error",
          field: "error_message",
          headerSort: false,
          headerFilter: "input",
          minWidth: 380,
          width: 460,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "")}</span>`,
        },
        {
          title: "Actions",
          field: "open_url",
          headerSort: false,
          download: false,
          minWidth: 200,
          width: 220,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const openUrl = row.open_url
            const retryUrl = row.retryable ? row.retry_url : null

            return `
              <div class="table-actions no-wrap">
                ${openUrl ? `<a class="btn small secondary" href="${escapeHtml(openUrl)}">Open</a>` : ""}
                ${retryUrl ? `<button class="btn small" data-action="background-job-failures-table#retry" data-url="${escapeHtml(retryUrl)}">Retry</button>` : ""}
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "background-job-failures-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      includeGlobal: true,
      topics: ["job_failures_changed"],
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

  async retry(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = button?.dataset?.url
    if (!url) return

    button.disabled = true

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "X-CSRF-Token": this.csrfToken,
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
      })

      if (!response.ok) {
        throw new Error("Retry request failed")
      }

      this.table?.replaceData()
    } catch (error) {
      if (window.showErrorModal) {
        window.showErrorModal("Retry failed", error.message)
      }
    } finally {
      button.disabled = false
    }
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 380, max: 920, bottomPadding: 38 })
  }
}
