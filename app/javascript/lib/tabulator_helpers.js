import { cable } from "@hotwired/turbo-rails"

const DEFAULT_PAGE_SIZES = Object.freeze([25, 50, 100, 200])
const INTERACTIVE_SELECTOR = "a,button,input,textarea,select,label,.btn,[role='button']"
let operationsConsumer

function getOperationsConsumer() {
  if (!operationsConsumer) operationsConsumer = cable.createConsumer()
  return operationsConsumer
}

function readPreferredPageSize(storageKey, fallback, allowedSizes) {
  if (!storageKey) return fallback

  try {
    const raw = window.localStorage.getItem(`tabulator:${storageKey}:pageSize`)
    const value = Number.parseInt(raw, 10)
    if (allowedSizes.includes(value)) return value
  } catch (_) {
    // Ignore storage access issues.
  }

  return fallback
}

function writePreferredPageSize(storageKey, value) {
  if (!storageKey) return

  try {
    window.localStorage.setItem(`tabulator:${storageKey}:pageSize`, String(value))
  } catch (_) {
    // Ignore storage access issues.
  }
}

export function registerCleanup(controller, cleanup) {
  if (typeof cleanup !== "function") return
  if (!Array.isArray(controller._tableCleanups)) controller._tableCleanups = []
  controller._tableCleanups.push(cleanup)
}

export function runTableCleanups(controller) {
  if (!Array.isArray(controller._tableCleanups)) return

  controller._tableCleanups.forEach((cleanup) => {
    try {
      cleanup()
    } catch (_) {
      // Best effort cleanup.
    }
  })

  controller._tableCleanups = []
}

export function adaptiveTableHeight(element, { min = 340, max = 860, bottomPadding = 42, fallbackOffset = 280 } = {}) {
  const viewport = window.innerHeight || 900
  const top = element?.getBoundingClientRect?.().top
  const available = Number.isFinite(top) ? (viewport - top - bottomPadding) : (viewport - fallbackOffset)
  const bounded = Math.max(min, Math.min(max, available))
  return `${Math.round(bounded)}px`
}

export function buildAjaxUrl(baseUrl, params) {
  const url = new URL(baseUrl, window.location.origin)

  Object.entries(params || {}).forEach(([key, value]) => {
    if (value === null || typeof value === "undefined") return

    const normalized = typeof value === "object" ? JSON.stringify(value) : String(value)
    if (normalized.length === 0) return

    url.searchParams.set(key, normalized)
  })

  return url.toString()
}

export function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

export function tabulatorBaseOptions({
  url,
  placeholder,
  height,
  columns,
  initialSort,
  storageKey,
  paginationSize = 50,
  paginationSizeSelector = DEFAULT_PAGE_SIZES,
}) {
  const selectedPageSize = readPreferredPageSize(storageKey, paginationSize, paginationSizeSelector)

  return {
    layout: "fitDataStretch",
    responsiveLayout: false,
    height,
    placeholder,

    ajaxURL: url,
    ajaxConfig: "GET",
    ajaxContentType: "json",
    ajaxResponse: (ajaxUrl, params, response) => response,
    ajaxURLGenerator: (ajaxUrl, config, params) => buildAjaxUrl(ajaxUrl, params),

    pagination: true,
    paginationMode: "remote",
    paginationSize: selectedPageSize,
    paginationSizeSelector,
    paginationCounter: "rows",

    sortMode: "remote",
    filterMode: "remote",
    initialSort,

    movableColumns: true,
    resizableColumnFit: true,
    renderHorizontal: "virtual",
    renderVerticalBuffer: 600,
    headerFilterLiveFilterDelay: 450,
    layoutColumnsOnNewData: true,

    columnDefaults: {
      vertAlign: "middle",
      headerSortTristate: true,
    },

    columns,
  }
}

export function attachTabulatorBehaviors(controller, table, { storageKey = null, paginationSize = 50 } = {}) {
  if (!controller || !table) return

  const rafId = window.requestAnimationFrame(() => {
    if (!controller.table || controller.table !== table) return
    installTableInteractions(controller, table)
    installAdaptiveResizing(controller, table)
  })

  registerCleanup(controller, () => window.cancelAnimationFrame(rafId))

  if (!storageKey) return

  const onPageSizeChanged = (size) => {
    writePreferredPageSize(storageKey, Number(size) || paginationSize)
  }

  table.on("pageSizeChanged", onPageSizeChanged)

  registerCleanup(controller, () => {
    if (typeof table.off === "function") {
      table.off("pageSizeChanged", onPageSizeChanged)
    }
  })
}

export function installAdaptiveResizing(controller, table) {
  let rafId = null

  const redraw = () => {
    rafId = null

    if (!controller.table || !table) return

    const nextHeight = controller._tableHeight?.()
    if (nextHeight) table.setHeight(nextHeight)
    table.redraw(true)
  }

  const requestRedraw = () => {
    if (rafId) return
    rafId = window.requestAnimationFrame(redraw)
  }

  window.addEventListener("resize", requestRedraw, { passive: true })

  let observer
  const resizeTarget = table.element?.parentElement || table.element
  if (typeof ResizeObserver !== "undefined" && resizeTarget) {
    observer = new ResizeObserver(() => requestRedraw())
    observer.observe(resizeTarget)
  }

  registerCleanup(controller, () => {
    if (rafId) window.cancelAnimationFrame(rafId)
    window.removeEventListener("resize", requestRedraw)
    observer?.disconnect()
  })
}

export function installTableInteractions(controller, table) {
  const holder = table.element?.querySelector(".tabulator-tableholder")
  if (!holder) return

  holder.classList.add("tabulator-scroll-ready")

  const onWheel = (event) => {
    const hasHorizontalOverflow = holder.scrollWidth > holder.clientWidth
    if (!hasHorizontalOverflow) return

    if (event.deltaY === 0) return

    const atTop = holder.scrollTop <= 0
    const atBottom = holder.scrollTop + holder.clientHeight >= holder.scrollHeight - 1
    const hasVerticalOverflow = holder.scrollHeight > holder.clientHeight
    const isVerticalBoundary = !hasVerticalOverflow || (event.deltaY < 0 ? atTop : atBottom)

    if (!event.shiftKey && !isVerticalBoundary) return

    holder.scrollLeft += event.deltaY
    event.preventDefault()
  }

  holder.addEventListener("wheel", onWheel, { passive: false })

  let dragState = null
  let dragSuppressionUntil = 0

  const startDrag = (event) => {
    if (event.pointerType !== "mouse") return
    if (event.button !== 0) return
    if (event.target.closest(INTERACTIVE_SELECTOR)) return

    dragState = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      startLeft: holder.scrollLeft,
      startTop: holder.scrollTop,
      moved: false,
    }

    holder.classList.add("tabulator-drag-scroll-active")
    document.body.classList.add("tabulator-user-select-lock")
  }

  const moveDrag = (event) => {
    if (!dragState) return
    if (event.pointerId !== dragState.pointerId) return

    const dx = event.clientX - dragState.startX
    const dy = event.clientY - dragState.startY

    if (!dragState.moved && (Math.abs(dx) > 2 || Math.abs(dy) > 2)) {
      dragState.moved = true
    }

    holder.scrollLeft = dragState.startLeft - dx
    holder.scrollTop = dragState.startTop - dy
  }

  const endDrag = (event) => {
    if (!dragState) return
    if (event.pointerId !== dragState.pointerId) return

    if (dragState.moved) {
      dragSuppressionUntil = Date.now() + 120
    }

    dragState = null
    holder.classList.remove("tabulator-drag-scroll-active")
    document.body.classList.remove("tabulator-user-select-lock")
  }

  const suppressClickAfterDrag = (event) => {
    if (Date.now() <= dragSuppressionUntil) {
      event.preventDefault()
      event.stopPropagation()
    }
  }

  holder.addEventListener("pointerdown", startDrag)
  window.addEventListener("pointermove", moveDrag)
  window.addEventListener("pointerup", endDrag)
  window.addEventListener("pointercancel", endDrag)
  holder.addEventListener("click", suppressClickAfterDrag, true)

  registerCleanup(controller, () => {
    holder.removeEventListener("wheel", onWheel)
    holder.removeEventListener("pointerdown", startDrag)
    holder.removeEventListener("click", suppressClickAfterDrag, true)
    window.removeEventListener("pointermove", moveDrag)
    window.removeEventListener("pointerup", endDrag)
    window.removeEventListener("pointercancel", endDrag)
    holder.classList.remove("tabulator-drag-scroll-active")
    holder.classList.remove("tabulator-scroll-ready")
    document.body.classList.remove("tabulator-user-select-lock")
  })
}

export function subscribeToOperationsTopics(controller, {
  accountId = 0,
  topics = [],
  debounceMs = 450,
  onRefresh = null,
} = {}) {
  if (!Array.isArray(topics) || topics.length === 0) return

  const uniqueTopics = new Set(topics)
  const consumer = getOperationsConsumer()
  const refresh = typeof onRefresh === "function" ? onRefresh : () => controller.table?.replaceData()

  let refreshTimer = null

  const scheduleRefresh = () => {
    if (refreshTimer) window.clearTimeout(refreshTimer)
    refreshTimer = window.setTimeout(() => {
      refreshTimer = null
      refresh()
    }, debounceMs)
  }

  const subscription = consumer.subscriptions.create(
    {
      channel: "OperationsChannel",
      account_id: Number(accountId) || 0,
    },
    {
      received: (message) => {
        if (!message || !uniqueTopics.has(String(message.topic || ""))) return
        scheduleRefresh()
      },
    }
  )

  registerCleanup(controller, () => {
    if (refreshTimer) window.clearTimeout(refreshTimer)
    consumer.subscriptions.remove(subscription)
  })
}
