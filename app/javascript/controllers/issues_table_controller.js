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
    this.tableEl = this.element.querySelector("[data-issues-table-target='table']")

    if (!this.tableEl) return
    this.ensureDetailsModal()

    const options = tabulatorBaseOptions({
      url: this.urlValue,
      placeholder: "No issues tracked",
      height: this._tableHeight(),
      initialSort: [{ column: "last_seen_at", dir: "desc" }],
      storageKey: "issues-table",
      columns: [
        {
          title: "Last Seen",
          field: "last_seen_at",
          headerSort: true,
          minWidth: 210,
          width: 225,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
        },
        {
          title: "Issue",
          field: "title",
          headerSort: true,
          headerFilter: "input",
          minWidth: 280,
          width: 330,
          formatter: (cell) => `<strong>${escapeHtml(cell.getValue() || "")}</strong>`,
        },
        {
          title: "Type",
          field: "issue_type",
          headerSort: false,
          headerFilter: "input",
          minWidth: 150,
          width: 170,
          formatter: (cell) => `<code>${escapeHtml(cell.getValue() || "")}</code>`,
        },
        {
          title: "Source",
          field: "source",
          headerSort: false,
          headerFilter: "input",
          minWidth: 190,
          width: 220,
          formatter: (cell) => `<span class="meta">${escapeHtml(cell.getValue() || "")}</span>`,
        },
        {
          title: "Severity",
          field: "severity",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", info: "info", warn: "warn", error: "error", critical: "critical" } },
          minWidth: 120,
          width: 130,
          formatter: (cell) => `<span class="pill">${escapeHtml(cell.getValue() || "error")}</span>`,
        },
        {
          title: "Status",
          field: "status",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", open: "open", pending: "pending", resolved: "resolved" } },
          minWidth: 120,
          width: 130,
          formatter: (cell) => `<span class="pill">${escapeHtml(cell.getValue() || "open")}</span>`,
        },
        {
          title: "Occurrences",
          field: "occurrences",
          headerSort: true,
          minWidth: 120,
          width: 130,
          hozAlign: "right",
          formatter: (cell) => Number(cell.getValue() || 0).toLocaleString(),
        },
        {
          title: "Context",
          field: "id",
          headerSort: false,
          minWidth: 190,
          width: 220,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            if (row.instagram_profile_id) {
              return `<span class="meta">Profile #${escapeHtml(row.instagram_profile_id)} (Account #${escapeHtml(row.instagram_account_id || "?")})</span>`
            }

            if (row.instagram_account_id) {
              return `<span class="meta">Account #${escapeHtml(row.instagram_account_id)}</span>`
            }

            return "<span class='meta'>System</span>"
          },
        },
        {
          title: "Summary",
          field: "details",
          headerSort: false,
          minWidth: 260,
          width: 320,
          formatter: (cell) => {
            const value = String(cell.getValue() || "")
            const preview = value.length > 110 ? `${value.slice(0, 110)}...` : value
            return `<span class="meta">${escapeHtml(preview || "-")}</span>`
          },
        },
        {
          title: "Actions",
          field: "id",
          headerSort: false,
          download: false,
          minWidth: 460,
          width: 500,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const status = row.status || "open"

            return `
              <div class="table-actions no-wrap">
                <button class="btn small secondary" data-action="issues-table#openDetails" data-id="${escapeHtml(row.id)}">Details</button>
                <button class="${status === "open" ? "btn small" : "btn small secondary"}" data-action="issues-table#setStatus" data-url="${escapeHtml(row.update_url)}" data-status="open">Open</button>
                <button class="${status === "pending" ? "btn small" : "btn small secondary"}" data-action="issues-table#setStatus" data-url="${escapeHtml(row.update_url)}" data-status="pending">Pending</button>
                <button class="${status === "resolved" ? "btn small" : "btn small secondary"}" data-action="issues-table#setStatus" data-url="${escapeHtml(row.update_url)}" data-status="resolved">Resolve</button>
                ${row.retryable ? `<button class="btn small secondary" data-action="issues-table#retryJob" data-url="${escapeHtml(row.retry_url)}">Retry Job</button>` : ""}
                ${row.failure_url ? `<a class="btn small secondary" href="${escapeHtml(row.failure_url)}">Failure</a>` : ""}
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "issues-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      includeGlobal: true,
      topics: ["issues_changed", "job_failures_changed"],
      onRefresh: () => this.table?.replaceData(),
    })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }

    if (this.detailsModalEl) {
      this.detailsModalInstance?.dispose?.()
      this.detailsModalInstance = null
      this.detailsModalEl.remove()
      this.detailsModalEl = null
    }
  }

  openDetails(event) {
    event.preventDefault()

    const rowId = String(event.currentTarget?.dataset?.id || "")
    if (!rowId || !this.table) return

    const row = this.table.getData().find((entry) => String(entry.id) === rowId)
    if (!row || !this.detailsModalInstance) return

    this.detailsTitleEl.textContent = row.title || `Issue #${rowId}`
    this.detailsMetaEl.textContent = [
      `Last seen: ${row.last_seen_at ? new Date(row.last_seen_at).toLocaleString() : "-"}`,
      `Severity: ${row.severity || "-"}`,
      `Status: ${row.status || "-"}`,
      `Occurrences: ${Number(row.occurrences || 0).toLocaleString()}`,
      this.contextLabelForRow(row),
    ].join(" | ")
    this.detailsBodyEl.textContent = row.details || "No details recorded."
    this.detailsLinksEl.innerHTML = row.failure_url
      ? `<a class="btn small secondary" href="${escapeHtml(row.failure_url)}">Open Failure Log</a>`
      : ""

    this.detailsModalInstance.show()
  }

  async setStatus(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = button?.dataset?.url
    const status = button?.dataset?.status

    if (!url || !status) return

    button.disabled = true

    try {
      const payload = new URLSearchParams({ status })

      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": this.csrfToken,
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest",
        },
        body: payload,
        credentials: "same-origin",
      })

      if (!response.ok) throw new Error("Issue update failed")

      this.table?.replaceData()
    } catch (error) {
      if (window.showErrorModal) {
        window.showErrorModal("Issue update failed", error.message)
      }
    } finally {
      button.disabled = false
    }
  }

  async retryJob(event) {
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

      if (!response.ok) throw new Error("Retry request failed")

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

  contextLabelForRow(row) {
    if (row.instagram_profile_id) {
      return `Profile #${row.instagram_profile_id} (Account #${row.instagram_account_id || "?"})`
    }
    if (row.instagram_account_id) {
      return `Account #${row.instagram_account_id}`
    }
    return "System"
  }

  ensureDetailsModal() {
    if (this.detailsModalEl) return

    const modal = document.createElement("div")
    modal.className = "modal fade app-media-modal issue-details-modal"
    modal.tabIndex = -1
    modal.setAttribute("aria-hidden", "true")
    modal.innerHTML = `
      <div class="modal-dialog modal-lg modal-dialog-centered modal-dialog-scrollable">
        <div class="modal-content">
          <div class="modal-header">
            <h5 class="modal-title" data-issue-details-title>Issue details</h5>
            <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
          </div>
          <div class="modal-body">
            <p class="meta mb-2" data-issue-details-meta></p>
            <div class="d-flex flex-wrap gap-2 mb-3" data-issue-details-links></div>
            <pre class="json-pre" data-issue-details-body></pre>
          </div>
        </div>
      </div>
    `

    this.element.appendChild(modal)
    this.detailsModalEl = modal
    this.detailsTitleEl = modal.querySelector("[data-issue-details-title]")
    this.detailsMetaEl = modal.querySelector("[data-issue-details-meta]")
    this.detailsBodyEl = modal.querySelector("[data-issue-details-body]")
    this.detailsLinksEl = modal.querySelector("[data-issue-details-links]")
    this.detailsModalInstance = window.bootstrap?.Modal?.getOrCreateInstance(modal)
  }
}
