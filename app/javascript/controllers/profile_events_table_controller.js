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
  view: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M12 5c-6.6 0-10 6.2-10 7s3.4 7 10 7 10-6.2 10-7-3.4-7-10-7Zm0 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm0-2.3a2.7 2.7 0 1 0 0-5.4 2.7 2.7 0 0 0 0 5.4Z"/>
    </svg>
  `,
  download: `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M11 3h2v10.1l3.6-3.6 1.4 1.4-6 6-6-6 1.4-1.4L11 13.1V3Zm-7 14h16v4H4v-4Z"/>
    </svg>
  `,
}

export default class extends Controller {
  static values = {
    url: String,
    accountId: Number,
    profileId: Number,
    profileUsername: String,
  }

  connect() {
    this.tableEl = this.element.querySelector("[data-profile-events-table-target='table']")
    if (!this.tableEl) return

    this.ensureMediaModal()

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
          formatter: (cell) => {
            const raw = String(cell.getValue() || "")
            const preview = raw.length > 320 ? `${raw.slice(0, 320)}...` : raw
            return `<span class="meta">${escapeHtml(preview)}</span>`
          },
        },
        {
          title: "Media",
          field: "media_download_url",
          headerSort: false,
          download: false,
          hozAlign: "center",
          minWidth: 120,
          width: 130,
          formatter: (cell) => {
            const row = cell.getRow().getData() || {}
            const viewUrl = row.media_url
            const downloadUrl = row.media_download_url
            const contentType = row.media_content_type || ""
            if (!viewUrl && !downloadUrl) return "-"

            const links = []
            if (viewUrl) {
              links.push(`
                <button
                  type="button"
                  class="btn small icon-only"
                  data-action="click->profile-events-table#openMedia"
                  data-media-url="${escapeHtml(viewUrl)}"
                  data-media-download-url="${escapeHtml(downloadUrl || viewUrl)}"
                  data-media-content-type="${escapeHtml(contentType)}"
                  data-media-preview-image-url="${escapeHtml(row.media_preview_image_url || "")}"
                  data-video-static-frame-only="${escapeHtml(String(row.video_static_frame_only || ""))}"
                  data-activity-kind="${escapeHtml(row.kind || "event")}"
                  data-occurred-at="${escapeHtml(row.occurred_at || row.detected_at || "")}"
                  title="View media"
                  aria-label="View media"
                >
                  ${ICONS.view}
                </button>
              `)
            }
            if (downloadUrl) {
              links.push(`<a class="btn small secondary icon-only" href="${escapeHtml(downloadUrl)}" target="_blank" rel="noreferrer" title="Download media" aria-label="Download media">${ICONS.download}</a>`)
            }

            return `<div class="table-actions">${links.join("")}</div>`
          },
        },
      ],
    })

    this.table = new Tabulator(this.tableEl, options)
    attachTabulatorBehaviors(this, this.table, { storageKey: "profile-events-table", paginationSize: 50 })

    subscribeToOperationsTopics(this, {
      accountId: this.accountIdValue,
      topics: ["profile_events_changed"],
      shouldRefresh: (message) => {
        const incomingProfileId = Number(message?.payload?.profile_id)
        return Number.isFinite(incomingProfileId) && incomingProfileId === this.profileIdValue
      },
      onRefresh: () => this.table?.replaceData(),
    })
  }

  disconnect() {
    runTableCleanups(this)

    if (this.table) {
      this.table.destroy()
      this.table = null
    }

    this.closeMedia()

    if (this.mediaModalEl) {
      this.mediaModalEl.remove()
      this.mediaModalEl = null
    }
  }

  openMedia(event) {
    event.preventDefault()
    if (!this.mediaModalEl) this.ensureMediaModal()

    const data = event.currentTarget.dataset
    const mediaUrl = String(data.mediaUrl || "")
    if (!mediaUrl) return

    const contentType = String(data.mediaContentType || "").toLowerCase()
    const previewImageUrl = String(data.mediaPreviewImageUrl || "")
    const staticVideo = this.toBoolean(data.videoStaticFrameOnly)
    const mediaPath = mediaUrl.split("?")[0].toLowerCase()
    const isVideo = contentType.startsWith("video/") ||
      mediaPath.endsWith(".mp4") ||
      mediaPath.endsWith(".mov") ||
      mediaPath.endsWith(".webm") ||
      mediaPath.endsWith(".m3u8")
    const activity = String(data.activityKind || "event").replaceAll("_", " ")
    const occurredAt = data.occurredAt ? new Date(data.occurredAt).toLocaleString() : "-"

    this.mediaTitleEl.textContent = `Media • ${activity}`
    this.mediaMetaEl.textContent = `Type: ${contentType || "unknown"} | Time: ${occurredAt}`
    this.mediaDownloadEl.href = data.mediaDownloadUrl || mediaUrl

    if (this.hasProfileUsernameValue && this.profileUsernameValue) {
      this.mediaAppProfileEl.textContent = `@${this.profileUsernameValue}`
      this.mediaAppProfileEl.href = this.hasProfileIdValue ? `/instagram_profiles/${encodeURIComponent(this.profileIdValue)}` : "#"
      this.mediaInstagramProfileEl.textContent = "IG"
      this.mediaInstagramProfileEl.href = `https://www.instagram.com/${encodeURIComponent(this.profileUsernameValue)}/`
    } else {
      this.mediaAppProfileEl.textContent = "-"
      this.mediaAppProfileEl.href = "#"
      this.mediaInstagramProfileEl.textContent = "-"
      this.mediaInstagramProfileEl.href = "#"
    }

    if (isVideo) {
      this.mediaImageEl.removeAttribute("src")
      this.mediaImageEl.classList.add("media-shell-hidden")
      this.mediaVideoShellEl.classList.remove("media-shell-hidden")
      this.mediaVideoEl.dataset.videoSource = mediaUrl
      this.mediaVideoEl.dataset.videoContentType = contentType
      this.mediaVideoEl.dataset.videoPosterUrl = previewImageUrl
      this.mediaVideoEl.dataset.videoStatic = staticVideo ? "true" : "false"
      this.mediaVideoEl.dispatchEvent(
        new CustomEvent("video-player:load", {
          detail: { src: mediaUrl, contentType, posterUrl: previewImageUrl, staticVideo, autoplay: false, immediate: false, preload: "none" },
        }),
      )
    } else {
      this.clearMediaVideo()
      this.mediaImageEl.src = mediaUrl
      this.mediaImageEl.classList.remove("media-shell-hidden")
    }

    if (this.mediaModalEl.open) this.mediaModalEl.close()
    this.mediaModalEl.showModal()
  }

  closeMedia() {
    this.clearMediaVideo()
    if (this.mediaModalEl?.open) this.mediaModalEl.close()
  }

  clearMediaVideo() {
    if (!this.mediaVideoEl || !this.mediaVideoShellEl) return
    this.mediaVideoEl.dispatchEvent(new CustomEvent("video-player:clear"))
    this.mediaVideoShellEl.classList.add("media-shell-hidden")
  }

  ensureMediaModal() {
    if (this.mediaModalEl) return

    const dialog = document.createElement("dialog")
    dialog.className = "modal profile-media-modal"
    dialog.innerHTML = `
      <div class="modal-header">
        <h3 data-profile-media-title>Event Media</h3>
        <button type="button" class="btn small secondary" data-action="click->profile-events-table#closeMedia">Close</button>
      </div>
      <div class="modal-grid">
        <div>
          <img data-profile-media-image alt="Profile event media" class="modal-media-image" />
          <div data-profile-media-video-shell class="story-video-player-shell audit-video-player-shell media-shell-hidden">
            <video data-profile-media-video data-controller="video-player" data-video-player-autoplay-value="false" data-video-player-load-on-play-value="true" controls playsinline preload="none"></video>
          </div>
        </div>
        <div>
          <p class="meta">
            Profile:
            <a data-profile-media-app-profile href="#">-</a>
            <span class="meta">|</span>
            <a data-profile-media-ig-profile href="#" target="_blank" rel="noopener noreferrer">IG</a>
          </p>
          <p class="meta" data-profile-media-meta></p>
          <div class="actions-row">
            <a data-profile-media-download class="btn secondary" href="#" target="_blank" rel="noreferrer">Download media</a>
          </div>
        </div>
      </div>
    `

    this.element.appendChild(dialog)

    this.mediaModalEl = dialog
    this.mediaTitleEl = dialog.querySelector("[data-profile-media-title]")
    this.mediaImageEl = dialog.querySelector("[data-profile-media-image]")
    this.mediaVideoEl = dialog.querySelector("[data-profile-media-video]")
    this.mediaVideoShellEl = dialog.querySelector("[data-profile-media-video-shell]")
    this.mediaMetaEl = dialog.querySelector("[data-profile-media-meta]")
    this.mediaDownloadEl = dialog.querySelector("[data-profile-media-download]")
    this.mediaAppProfileEl = dialog.querySelector("[data-profile-media-app-profile]")
    this.mediaInstagramProfileEl = dialog.querySelector("[data-profile-media-ig-profile]")

    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) this.closeMedia()
    })
    dialog.addEventListener("close", () => this.clearMediaVideo())
  }

  _tableHeight() {
    return adaptiveTableHeight(this.tableEl, { min: 340, max: 760, bottomPadding: 38 })
  }

  toBoolean(raw) {
    if (typeof raw === "boolean") return raw
    const value = String(raw || "").trim().toLowerCase()
    return ["1", "true", "yes", "on"].includes(value)
  }
}
