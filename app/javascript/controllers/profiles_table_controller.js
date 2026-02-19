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
  fetch: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M12 4a8 8 0 0 1 7.7 6h2.1A10 10 0 0 0 12 2v3l4 3-4 3V4Zm0 16a8 8 0 0 1-7.7-6H2.2A10 10 0 0 0 12 22v-3l-4-3 4-3v7Z"/>
    </svg>
  `,
  verify: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M12 2 4 5v6c0 5 3.4 9.7 8 11 4.6-1.3 8-6 8-11V5l-8-3Zm-1 13-3-3 1.4-1.4L11 12.2l3.6-3.6L16 10l-5 5Z"/>
    </svg>
  `,
  avatar: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Zm0 2v10h16V7H4Zm3 8 3-4 2.5 3 2-2 3.5 3H7Zm3-6.5A1.5 1.5 0 1 0 10 11a1.5 1.5 0 0 0 0-3Z"/>
    </svg>
  `,
  analyze: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M11 2h2l.9 3.2L17 6l-2.1 2.1.6 3.1L12 9.8 8.5 11.2l.6-3.1L7 6l3.1-.8L11 2Zm-7 12h2l.7 2.4L9 17l-1.8 1.8.5 2.2L5 19.9 2.3 21l.5-2.2L1 17l2.3-.6L4 14Zm13 0h3l1 3 3 1-3 1-1 3-1-3-3-1 3-1 1-3Z"/>
    </svg>
  `,
}

export default class extends Controller {
  static values = { url: String, accountId: Number }

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
          minWidth: 210,
          width: 230,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const openUrl = `/instagram_profiles/${row.id}`
            const fetchUrl = `/instagram_profiles/${row.id}/fetch_details`
            const verifyUrl = `/instagram_profiles/${row.id}/verify_messageability`
            const avatarUrl = `/instagram_profiles/${row.id}/download_avatar`
            const analyzeUrl = `/instagram_profiles/${row.id}/analyze`

            return `
              <div class="table-actions no-wrap">
                <a class="btn small icon-only" href="${openUrl}" title="Open profile" aria-label="Open profile">${ICONS.open}</a>
                <button class="btn small secondary icon-only" data-action="profiles-table#post" data-url="${fetchUrl}" title="Fetch profile details" aria-label="Fetch profile details">${ICONS.fetch}</button>
                <button class="btn small secondary icon-only" data-action="profiles-table#post" data-url="${verifyUrl}" title="Verify messageability" aria-label="Verify messageability">${ICONS.verify}</button>
                <button class="btn small secondary icon-only" data-action="profiles-table#post" data-url="${avatarUrl}" title="Sync avatar" aria-label="Sync avatar">${ICONS.avatar}</button>
                <button class="btn small secondary icon-only" data-action="profiles-table#post" data-url="${analyzeUrl}" title="Analyze profile" aria-label="Analyze profile">${ICONS.analyze}</button>
              </div>
            `
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "profiles-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      topics: ["profiles_table_changed"],
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
