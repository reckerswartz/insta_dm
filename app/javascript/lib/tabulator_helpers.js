import { getCableConsumer } from "./cable_consumer"

const DEFAULT_PAGE_SIZES = [25, 50, 100, 200]
const INTERACTIVE_SELECTOR = "a,button,input,textarea,select,label,.btn,[role='button']"
let operationsConsumer

function controllerOwnsTable(controller, table) {
  if (!controller || !table) return false
  if (controller.table && controller.table === table) return true
  if (controller.tableInstance && controller.tableInstance === table) return true
  return false
}

function getOperationsConsumer() {
  if (!operationsConsumer) operationsConsumer = getCableConsumer()
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
  const pageSizeSelector = Array.isArray(paginationSizeSelector) ? [...paginationSizeSelector] : [...DEFAULT_PAGE_SIZES]
  const selectedPageSize = readPreferredPageSize(storageKey, paginationSize, pageSizeSelector)

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
    paginationSizeSelector: pageSizeSelector,
    paginationButtonCount: 7,
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
    if (!controllerOwnsTable(controller, table)) return
    installTableInteractions(controller, table)
    installAdaptiveResizing(controller, table)
    installPaginationControls(controller, table)
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

export function installPaginationControls(controller, table) {
  if (!table?.options?.pagination) return

  const tableEl = table.element
  if (!tableEl?.parentElement) return

  const bar = document.createElement("div")
  bar.className = "tabulator-external-pagination"
  bar.innerHTML = `
    <div class="tabulator-pagination-actions" role="group" aria-label="Table pagination controls">
      <button type="button" class="btn small secondary icon-only" data-page-nav="first" aria-label="First page" title="First page">
        <span aria-hidden="true">&laquo;</span>
      </button>
      <button type="button" class="btn small secondary icon-only" data-page-nav="prev" aria-label="Previous page" title="Previous page">
        <span aria-hidden="true">&lsaquo;</span>
      </button>
      <span class="tabulator-pagination-meta" data-page-meta>Page 1 of 1</span>
      <button type="button" class="btn small secondary icon-only" data-page-nav="next" aria-label="Next page" title="Next page">
        <span aria-hidden="true">&rsaquo;</span>
      </button>
      <button type="button" class="btn small secondary icon-only" data-page-nav="last" aria-label="Last page" title="Last page">
        <span aria-hidden="true">&raquo;</span>
      </button>
    </div>
  `

  tableEl.insertAdjacentElement("afterend", bar)

  const metaEl = bar.querySelector("[data-page-meta]")
  const firstBtn = bar.querySelector("[data-page-nav='first']")
  const prevBtn = bar.querySelector("[data-page-nav='prev']")
  const nextBtn = bar.querySelector("[data-page-nav='next']")
  const lastBtn = bar.querySelector("[data-page-nav='last']")

  const goToPage = (page) => {
    const maxPage = Number(table.getPageMax?.()) || 1
    const target = Math.max(1, Math.min(maxPage, Number(page) || 1))
    if (typeof table.setPage === "function") table.setPage(target)
  }

  const syncUi = () => {
    const currentPage = Number(table.getPage?.()) || 1
    const maxPageRaw = Number(table.getPageMax?.())
    const maxPage = Number.isFinite(maxPageRaw) && maxPageRaw > 0 ? maxPageRaw : 1

    if (metaEl) metaEl.textContent = `Page ${currentPage} of ${maxPage}`
    if (firstBtn) firstBtn.disabled = currentPage <= 1
    if (prevBtn) prevBtn.disabled = currentPage <= 1
    if (nextBtn) nextBtn.disabled = currentPage >= maxPage
    if (lastBtn) lastBtn.disabled = currentPage >= maxPage
  }

  const onFirst = () => goToPage(1)
  const onPrev = () => {
    if (typeof table.previousPage === "function") {
      table.previousPage()
      return
    }
    const currentPage = Number(table.getPage?.()) || 1
    goToPage(currentPage - 1)
  }
  const onNext = () => {
    if (typeof table.nextPage === "function") {
      table.nextPage()
      return
    }
    const currentPage = Number(table.getPage?.()) || 1
    goToPage(currentPage + 1)
  }
  const onLast = () => {
    const maxPage = Number(table.getPageMax?.()) || 1
    goToPage(maxPage)
  }

  firstBtn?.addEventListener("click", onFirst)
  prevBtn?.addEventListener("click", onPrev)
  nextBtn?.addEventListener("click", onNext)
  lastBtn?.addEventListener("click", onLast)

  const onPageLoaded = () => syncUi()
  const onDataLoaded = () => syncUi()
  const onRenderComplete = () => syncUi()
  const onPageSizeChanged = () => {
    if (typeof table.setPage === "function") table.setPage(1)
    syncUi()
  }

  table.on("pageLoaded", onPageLoaded)
  table.on("dataLoaded", onDataLoaded)
  table.on("renderComplete", onRenderComplete)
  table.on("pageSizeChanged", onPageSizeChanged)

  const initialSync = window.requestAnimationFrame(syncUi)

  registerCleanup(controller, () => {
    window.cancelAnimationFrame(initialSync)
    firstBtn?.removeEventListener("click", onFirst)
    prevBtn?.removeEventListener("click", onPrev)
    nextBtn?.removeEventListener("click", onNext)
    lastBtn?.removeEventListener("click", onLast)
    if (typeof table.off === "function") {
      table.off("pageLoaded", onPageLoaded)
      table.off("dataLoaded", onDataLoaded)
      table.off("renderComplete", onRenderComplete)
      table.off("pageSizeChanged", onPageSizeChanged)
    }
    bar.remove()
  })
}

export function installAdaptiveResizing(controller, table) {
  let rafId = null

  const redraw = () => {
    rafId = null

    if (!table || !controllerOwnsTable(controller, table)) return

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
  includeGlobal = false,
  topics = [],
  debounceMs = 450,
  shouldRefresh = null,
  onRefresh = null,
} = {}) {
  if (!Array.isArray(topics) || topics.length === 0) return

  const uniqueTopics = new Set(topics)
  const consumer = getOperationsConsumer()
  const shouldRefreshForMessage = typeof shouldRefresh === "function" ? shouldRefresh : () => true
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
      include_global: Boolean(includeGlobal || Number(accountId) <= 0),
    },
    {
      received: (message) => {
        if (!message || !uniqueTopics.has(String(message.topic || ""))) return
        if (!shouldRefreshForMessage(message)) return
        scheduleRefresh()
      },
    }
  )

  registerCleanup(controller, () => {
    if (refreshTimer) window.clearTimeout(refreshTimer)
    consumer.subscriptions.remove(subscription)
  })
}
