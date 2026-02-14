import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    this.tableEl = this.element.querySelector("[data-profiles-table-target='table']")

    if (!this.tableEl) return

    this.table = new Tabulator(this.tableEl, {
      layout: "fitColumns",
      height: this._tableHeight(),
      placeholder: "No profiles found",

      ajaxURL: this.urlValue || "/instagram_profiles.json",
      ajaxConfig: "GET",
      ajaxContentType: "json",
      ajaxResponse: (url, params, response) => response,

      pagination: true,
      paginationMode: "remote",
      paginationSize: 50,
      paginationSizeSelector: [25, 50, 100, 200],

      sortMode: "remote",
      filterMode: "remote",
      initialSort: [{ column: "username", dir: "asc" }],

      columns: [
        {
          title: "Avatar",
          field: "avatar_url",
          hozAlign: "center",
          width: 70,
          headerSort: false,
          formatter: (cell) => {
            const url = cell.getValue()
            if (!url) return "<div class='avatar placeholder'></div>"
            return `<img class="avatar" src="${this._escape(url)}" alt="" loading="lazy">`
          },
        },
        { title: "Username", field: "username", headerSort: true, headerFilter: "input", widthGrow: 1 },
        { title: "Name", field: "display_name", headerSort: true, headerFilter: "input", widthGrow: 2 },
        {
          title: "Following",
          field: "following",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          width: 110,
        },
        {
          title: "Follows you",
          field: "follows_you",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          width: 120,
        },
        {
          title: "Mutual",
          field: "mutual",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No" } },
          formatter: (cell) => (cell.getValue() ? "Yes" : "No"),
          width: 90,
        },
        {
          title: "Can message",
          field: "can_message",
          headerSort: true,
          headerFilter: "list",
          headerFilterParams: { values: { "": "Any", true: "Yes", false: "No", unknown: "Unknown" } },
          formatter: (cell) => {
            const v = cell.getValue()
            if (v === true) return "<span class='yes'>Yes</span>"
            if (v === false) return "<span class='no'>No</span>"
            return "<span class='muted'>Unknown</span>"
          },
          width: 120,
        },
        {
          title: "Last synced",
          field: "last_synced_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          width: 200,
        },
        {
          title: "Last active",
          field: "last_active_at",
          headerSort: true,
          formatter: (cell) => (cell.getValue() ? new Date(cell.getValue()).toLocaleString() : "-"),
          width: 200,
        },
        {
          title: "Actions",
          field: "id",
          headerSort: false,
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const open = `/instagram_profiles/${row.id}`
            const fetch = `/instagram_profiles/${row.id}/fetch_details`
            const verify = `/instagram_profiles/${row.id}/verify_messageability`
            const avatar = `/instagram_profiles/${row.id}/download_avatar`
            const analyze = `/instagram_profiles/${row.id}/analyze`
            return `
              <div class="table-actions">
                <a class="btn small" href="${open}">Open</a>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${fetch}">Fetch</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${verify}">Verify</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${avatar}">Avatar</button>
                <button class="btn small secondary" data-action="profiles-table#post" data-url="${analyze}">Analyze</button>
              </div>
            `
          },
          widthGrow: 2,
        },
      ],

      ajaxURLGenerator: (url, config, params) => this._urlWithParams(url, params),
    })
  }

  async post(event) {
    event.preventDefault()
    const url = event.currentTarget?.dataset?.url
    if (!url) return

    await fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": this.csrfToken || "",
        "X-Requested-With": "XMLHttpRequest",
        "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
      },
      credentials: "same-origin",
    })
  }

  _tableHeight() {
    const h = window.innerHeight || 900
    const target = h - 310
    return `${Math.max(360, Math.min(620, target))}px`
  }

  _urlWithParams(baseUrl, params) {
    const u = new URL(baseUrl, window.location.origin)
    Object.entries(params || {}).forEach(([k, v]) => {
      if (v === null || typeof v === "undefined") return
      const s = (typeof v === "object") ? JSON.stringify(v) : String(v)
      if (s.length === 0) return
      u.searchParams.set(k, s)
    })
    return u.toString()
  }

  _escape(s) {
    return String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;")
  }
}
