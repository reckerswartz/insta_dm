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
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.content || ""
    this.tableEl = this.element.querySelector("[data-profiles-table-target='table']")

    if (!this.tableEl) return

    const options = tabulatorBaseOptions({
      url: this.urlValue || "/instagram_profiles.json",
      placeholder: "No profiles found",
      height: this._tableHeight(),
      initialSort: [{ column: "username", dir: "asc" }],
      storageKey: "profiles-table",
      columns: [
        {
          title: "Avatar",
          field: "avatar_url",
          hozAlign: "center",
          width: 86,
          minWidth: 70,
          headerSort: false,
          formatter: (cell) => {
            const url = cell.getValue()
            if (!url) return "<div class='avatar placeholder'></div>"
            return `<img class="avatar" src="${escapeHtml(url)}" alt="" loading="lazy">`
          },
        },
        { title: "Username", field: "username", headerSort: true, headerFilter: "input", minWidth: 170, width: 190 },
        { title: "Name", field: "display_name", headerSort: true, headerFilter: "input", minWidth: 210, width: 240 },
        {
          title: "Following",
          field: "following",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          minWidth: 110,
          width: 120,
        },
        {
          title: "Follows You",
          field: "follows_you",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          minWidth: 130,
          width: 140,
        },
        {
          title: "Mutual",
          field: "mutual",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          minWidth: 100,
          width: 110,
        },
        {
          title: "Can Message",
          field: "can_message",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No", unknown: "Unknown" } },
          formatter: (cell) => {
            const value = cell.getValue()
            if (value === true) return "<span class='yes'>Yes</span>"
            if (value === false) return "<span class='no'>No</span>"
            return "<span class='muted'>Unknown</span>"
          },
          minWidth: 130,
          width: 145,
        },
        {
          title: "Last Synced",
          field: "last_synced_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          minWidth: 220,
          width: 235,
        },
        {
          title: "Last Active",
          field: "last_active_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          minWidth: 220,
          width: 235,
        },
        {
          title: "Actions",
          field: "id",
          headerSort: false,
          minWidth: 410,
          width: 440,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const openUrl = `/instagram_profiles/${row.id}`
            const fetchUrl = `/instagram_profiles/${row.id}/fetch_details`
            const verifyUrl = `/instagram_profiles/${row.id}/verify_messageability`
            const avatarUrl = `/instagram_profiles/${row.id}/download_avatar`
            const analyzeUrl = `/instagram_profiles/${row.id}/analyze`

            return `
              <div class="table-actions no-wrap">
                <a class="btn small" href="${openUrl}">Open</a>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${fetchUrl}">Fetch</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${verifyUrl}">Verify</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${avatarUrl}">Avatar</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${analyzeUrl}">Analyze</button>
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "profiles-table", paginationSize: 50 })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }
  }

  async post(event) {
    event.preventDefault()

    const button = event.currentTarget
    const url = button?.dataset?.url
    if (!url) return

    button.disabled = true

    try {
      await fetch(url, {
        method: "POST",
        headers: {
          "X-CSRF-Token": this.csrfToken,
          "X-Requested-With": "XMLHttpRequest",
          "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
        },
        credentials: "same-origin",
      })
    } finally {
      button.disabled = false
    }
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 380, max: 940, bottomPadding: 38 })
  }
}
