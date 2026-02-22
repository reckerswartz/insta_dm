import { getCableConsumer } from "./cable_consumer"

const DEFAULT_PAGE_SIZES = [25, 50, 100, 200]
const INTERACTIVE_SELECTOR = "a,button,input,textarea,select,label,.btn,[role='button']"
const TABLE_REFRESH_WARN_MS = 1600
const NEVER_SETTLED_PROMISE = new Promise(() => {})
let operationsConsumer
let tableAddonSequence = 0

function tabulatorDebugWarningsEnabled() {
  return Boolean(window.__TABULATOR_DEBUG_WARNINGS === true)
}

function isAbortLikeError(error) {
  if (!error) return false
  if (String(error.name || "") === "AbortError") return true

  const message = String(error.message || "").toLowerCase()
  return message.includes("abort")
}

function createCancelableAjaxRequest() {
  const controllers = new Set()
  let disposed = false

  const request = (url, config, params) => {
    if (disposed) return NEVER_SETTLED_PROMISE

    const controller = new AbortController()
    controllers.add(controller)

    const nextConfig = {
      ...(config || {}),
      signal: controller.signal,
      headers: {
        ...((config && config.headers) || {}),
      },
    }

    if (!nextConfig.headers.Accept) nextConfig.headers.Accept = "application/json"
    if (!nextConfig.headers["X-Requested-With"]) nextConfig.headers["X-Requested-With"] = "XMLHttpRequest"

    if (typeof nextConfig.mode === "undefined") nextConfig.mode = "cors"
    if (nextConfig.mode === "cors") {
      if (typeof nextConfig.headers.Origin === "undefined") nextConfig.headers.Origin = window.location.origin
      if (typeof nextConfig.credentials === "undefined") nextConfig.credentials = "same-origin"
    } else if (typeof nextConfig.credentials === "undefined") {
      nextConfig.credentials = "include"
    }

    const method = String(nextConfig.method || "GET").toUpperCase()
    const requestUrl = (method === "GET" || method === "HEAD")
      ? buildAjaxUrl(url, params)
      : url

    return fetch(requestUrl, nextConfig)
      .then((response) => {
        if (!response.ok) {
          const error = new Error(`HTTP ${response.status}`)
          error.status = response.status
          error.statusText = response.statusText
          throw error
        }
        return response.json()
      })
      .catch((error) => {
        if (disposed || isAbortLikeError(error)) {
          controllers.delete(controller)
          return NEVER_SETTLED_PROMISE
        }
        throw error
      })
      .finally(() => {
        controllers.delete(controller)
      })
  }

  request.abortPending = () => {
    controllers.forEach((controller) => {
      try {
        controller.abort()
      } catch (_) {
        // Ignore cancellation errors.
      }
    })
    controllers.clear()
  }

  request.dispose = () => {
    disposed = true
    request.abortPending()
  }

  return request
}

function controllerOwnsTable(controller, table) {
  if (!controller || !table) return false
  if (controller.table && controller.table === table) return true
  if (controller.tableInstance && controller.tableInstance === table) return true
  return false
}

function tableStillMounted(table) {
  const tableEl = table?.element
  if (!tableEl || !tableEl.isConnected) return false
  const holder = tableEl.querySelector(".tabulator-tableholder")
  // Tabulator redraw/height logic requires an attached holder element.
  return Boolean(holder && holder.isConnected)
}

function tableCanRedraw(table) {
  const tableEl = table?.element
  if (!tableEl || !tableEl.isConnected) return false
  if (tableEl.offsetParent === null && window.getComputedStyle(tableEl).position !== "fixed") return false

  const holder = tableEl.querySelector(".tabulator-tableholder")
  if (!holder || !holder.isConnected) return false

  const holderWidth = holder.getBoundingClientRect?.().width
  if (!Number.isFinite(holderWidth) || holderWidth <= 0) return false

  if (table?.rowManager && !table.rowManager.element) return false
  return true
}

function getOperationsConsumer() {
  if (!operationsConsumer) operationsConsumer = getCableConsumer()
  return operationsConsumer
}

function ensureTableAddonId(tableEl) {
  if (!tableEl) return `table-addon-${Date.now()}-${++tableAddonSequence}`
  if (!tableEl.dataset.tabulatorAddonId) {
    tableEl.dataset.tabulatorAddonId = `tabulator-addon-${++tableAddonSequence}`
  }
  return tableEl.dataset.tabulatorAddonId
}

function registerTableDebugReference(table, storageKey) {
  if (typeof window === "undefined" || !table) return null

  if (!window.__appTabulatorRegistry) {
    window.__appTabulatorRegistry = {}
  }

  const registry = window.__appTabulatorRegistry
  const baseKey = storageKey ? String(storageKey) : `table-${++tableAddonSequence}`

  let registryKey = baseKey
  let suffix = 1
  while (registry[registryKey] && registry[registryKey] !== table) {
    suffix += 1
    registryKey = `${baseKey}-${suffix}`
  }

  registry[registryKey] = table
  if (table.element) table.element.dataset.tabulatorRegistryKey = registryKey
  return registryKey
}

function unregisterTableDebugReference(table, registryKey) {
  if (typeof window === "undefined" || !registryKey) return
  const registry = window.__appTabulatorRegistry
  if (!registry) return

  if (!table || registry[registryKey] === table) {
    delete registry[registryKey]
  }

  if (table?.element) {
    delete table.element.dataset.tabulatorRegistryKey
  }

  if (Object.keys(registry).length === 0) {
    delete window.__appTabulatorRegistry
  }
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

function estimateTotalRows(table) {
  if (!table) return 0

  const pageModule = table.modules?.page
  const mode = String(pageModule?.mode || table.options?.paginationMode || "local")
  const pageRows = Array.isArray(table.getRows?.("visible")) ? table.getRows("visible").length : 0
  const pageSizeRaw = Number(pageModule?.size)
  const pageSize = Number.isFinite(pageSizeRaw) && pageSizeRaw > 0
    ? pageSizeRaw
    : (Number(table.options?.paginationSize) || 25)
  const currentPage = Math.max(1, Number(pageModule?.page) || 1)
  const maxPage = Math.max(1, Number(pageModule?.max) || 1)

  const activeCount = Number(table.getDataCount?.("active"))
  const remoteEstimate = Number(pageModule?.remoteRowCountEstimate)
  if (mode !== "remote" && Number.isFinite(activeCount) && activeCount >= 0) return activeCount
  if (Number.isFinite(remoteEstimate) && remoteEstimate >= 0) return remoteEstimate

  if (mode === "remote" && maxPage > 1) {
    if (currentPage >= maxPage) return ((maxPage - 1) * pageSize) + pageRows
    return maxPage * pageSize
  }

  if (Number.isFinite(activeCount) && activeCount >= 0) return activeCount
  return pageRows
}

function formatMetaTimestamp(value) {
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return "not yet loaded"

  return date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })
}

function installTableMetaBar(controller, table) {
  const scopeEl = controller?.element
  if (!scopeEl || !table) return false

  const countEl = scopeEl.querySelector("[data-table-meta-count]")
  const updatedEl = scopeEl.querySelector("[data-table-meta-updated]")
  const stateEl = scopeEl.querySelector("[data-table-meta-state]")
  const runtimeEl = scopeEl.querySelector(".table-meta-runtime")

  if (!countEl && !updatedEl && !stateEl && !runtimeEl) return false

  let isLoading = false
  let loadedOnce = false
  let lastLoadedAt = null

  const sync = ({ loading = null, markLoaded = false } = {}) => {
    if (typeof loading === "boolean") isLoading = loading
    if (markLoaded) {
      isLoading = false
      loadedOnce = true
      lastLoadedAt = new Date()
    }

    const totalRows = estimateTotalRows(table)
    if (countEl) countEl.textContent = Number(totalRows || 0).toLocaleString()

    if (updatedEl) {
      if (!loadedOnce && isLoading) {
        updatedEl.textContent = "loading..."
      } else if (!loadedOnce) {
        updatedEl.textContent = "not yet loaded"
      } else {
        updatedEl.textContent = formatMetaTimestamp(lastLoadedAt)
      }
    }

    if (stateEl) {
      if (isLoading) {
        stateEl.textContent = "Refreshing..."
      } else if (loadedOnce) {
        stateEl.textContent = "Up to date"
      } else {
        stateEl.textContent = "Idle"
      }
    }

    runtimeEl?.classList.toggle("is-loading", isLoading)
  }

  const onDataLoading = () => sync({ loading: true })
  const onDataLoaded = () => sync({ markLoaded: true })
  const onPageLoaded = () => sync()
  const onDataProcessed = () => sync()
  const onRenderComplete = () => sync()
  const onTableBuilt = () => sync()

  table.on("dataLoading", onDataLoading)
  table.on("dataLoaded", onDataLoaded)
  table.on("pageLoaded", onPageLoaded)
  table.on("dataProcessed", onDataProcessed)
  table.on("renderComplete", onRenderComplete)
  table.on("tableBuilt", onTableBuilt)

  sync({ loading: true })

  registerCleanup(controller, () => {
    if (typeof table.off === "function") {
      table.off("dataLoading", onDataLoading)
      table.off("dataLoaded", onDataLoaded)
      table.off("pageLoaded", onPageLoaded)
      table.off("dataProcessed", onDataProcessed)
      table.off("renderComplete", onRenderComplete)
      table.off("tableBuilt", onTableBuilt)
    }
    runtimeEl?.classList.remove("is-loading")
  })

  return true
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

export function adaptiveTableHeight(element, {
  min = 340,
  max = 860,
  bottomPadding = 42,
  fallbackOffset = 280,
  compactMin = 220,
  offscreenViewportFactor = 1.1,
} = {}) {
  const viewport = window.innerHeight || 900
  const rect = element?.getBoundingClientRect?.()
  const top = rect?.top
  const available = Number.isFinite(top) ? (viewport - top - bottomPadding) : (viewport - fallbackOffset)

  const compactFloor = Math.max(180, Math.min(min, compactMin))
  const isFarOffscreen = Number.isFinite(top) && (
    top > (viewport * offscreenViewportFactor) ||
    top < (viewport * -offscreenViewportFactor)
  )
  const effectiveMin = isFarOffscreen ? compactFloor : min
  const bounded = Math.max(effectiveMin, Math.min(max, available))
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
  const ajaxRequestFunc = createCancelableAjaxRequest()

  return {
    layout: "fitDataStretch",
    responsiveLayout: false,
    height,
    placeholder,

    ajaxURL: url,
    ajaxConfig: "GET",
    ajaxContentType: "json",
    ajaxRequestFunc,
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

    movableColumns: true,
    resizableColumnFit: true,
    renderHorizontal: "virtual",
    renderVerticalBuffer: 360,
    headerFilterLiveFilterDelay: 550,
    layoutColumnsOnNewData: false,

    columnDefaults: {
      vertAlign: "middle",
      headerSortTristate: true,
    },

    columns,
  }
}

export function attachTabulatorBehaviors(
  controller,
  table,
  { storageKey = null, paginationSize = 50 } = {},
) {
  if (!controller || !table) return

  const tableEl = table.element
  const addonId = ensureTableAddonId(tableEl)
  const debugRegistryKey = registerTableDebugReference(table, storageKey)

  if (storageKey && tableEl) {
    tableEl.dataset.tabulatorStorageKey = storageKey
  }
  if (tableEl) {
    tableEl.classList.add("tabulator-pagination-managed")
    tableEl.dataset.tabulatorPaginationMode = table?.options?.pagination ? "external" : "disabled"
  }

  const rafId = window.requestAnimationFrame(() => {
    if (!controllerOwnsTable(controller, table)) return
    installTableMetaBar(controller, table)
    installTableInteractions(controller, table)
    installAdaptiveResizing(controller, table)
    installTableLifecycleMonitor(controller, table, { storageKey })
    installPaginationControls(controller, table, { addonId, force: true })
  })

  registerCleanup(controller, () => window.cancelAnimationFrame(rafId))

  const ajaxRequest = table?.options?.ajaxRequestFunc
  if (ajaxRequest && typeof ajaxRequest.dispose === "function") {
    registerCleanup(controller, () => ajaxRequest.dispose())
  }

  const onTableBuilt = () => installPaginationControls(controller, table, { addonId, force: true })
  const onDataLoaded = () => installPaginationControls(controller, table, { addonId, force: true })
  table.on("tableBuilt", onTableBuilt)
  table.on("dataLoaded", onDataLoaded)

  registerCleanup(controller, () => {
    if (typeof table.off === "function") {
      table.off("tableBuilt", onTableBuilt)
      table.off("dataLoaded", onDataLoaded)
    }
    unregisterTableDebugReference(table, debugRegistryKey)
    if (tableEl) {
      tableEl.classList.remove("tabulator-pagination-managed")
      delete tableEl.dataset.tabulatorPaginationMode
      delete tableEl.dataset.tabulatorAddonId
      if (storageKey) delete tableEl.dataset.tabulatorStorageKey
    }
  })

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

export function installPaginationControls(controller, table, { addonId = null, force = false } = {}) {
  if (!table?.options?.pagination) return false

  const tableEl = table.element
  if (!tableEl?.parentElement) return false

  const hasPageModule = Boolean(table.modules?.page)
  const hasFooter = Boolean(tableEl.querySelector(".tabulator-footer"))
  if (!hasPageModule || !hasFooter) return false

  const resolvedAddonId = addonId || ensureTableAddonId(tableEl)
  const existingBar = tableEl.parentElement.querySelector(`.tabulator-external-pagination[data-tabulator-addon-for="${resolvedAddonId}"]`)
  if (existingBar) return true

  const configuredPageSizes = Array.isArray(table.options?.paginationSizeSelector)
    ? table.options.paginationSizeSelector.filter((size) => Number(size) > 0).map((size) => Number(size))
    : []
  const defaultPageSize = Number(table.options?.paginationSize) || 25
  const selectedPageSize = Number(table.modules?.page?.size) || defaultPageSize
  const pageSizes = Array.from(new Set([defaultPageSize, selectedPageSize, ...configuredPageSizes]))
    .filter((size) => Number(size) > 0)
    .sort((a, b) => a - b)

  const bar = document.createElement("div")
  bar.className = "tabulator-external-pagination"
  bar.dataset.tabulatorAddonFor = resolvedAddonId

  const optionsHtml = pageSizes.map((size) => `<option value="${size}">${size}</option>`).join("")
  bar.innerHTML = `
    <div class="tabulator-pagination-meta-group">
      <label class="tabulator-page-size-control" aria-label="Rows per page">
        <span>Rows</span>
        <select data-page-size>
          ${optionsHtml}
        </select>
      </label>
      <span class="tabulator-pagination-summary" data-page-summary>Showing 0 results</span>
    </div>
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

  const pageSizeSelect = bar.querySelector("[data-page-size]")
  const summaryEl = bar.querySelector("[data-page-summary]")
  const metaEl = bar.querySelector("[data-page-meta]")
  const firstBtn = bar.querySelector("[data-page-nav='first']")
  const prevBtn = bar.querySelector("[data-page-nav='prev']")
  const nextBtn = bar.querySelector("[data-page-nav='next']")
  const lastBtn = bar.querySelector("[data-page-nav='last']")

  if (tableEl) {
    tableEl.classList.add("tabulator-pagination-managed")
    tableEl.dataset.tabulatorPaginationMode = "external"
  }

  const pageStats = () => {
    const pageModule = table.modules?.page
    const mode = String(pageModule?.mode || table.options?.paginationMode || "local")
    const currentPage = Number(pageModule?.page) || 1
    const pageSizeRaw = Number(pageModule?.size)
    const pageSize = Number.isFinite(pageSizeRaw) && pageSizeRaw > 0 ? pageSizeRaw : defaultPageSize
    const pageRows = Array.isArray(table.getRows?.("visible")) ? table.getRows("visible").length : 0

    let totalRows
    if (mode === "remote") {
      const remoteEstimate = Number(pageModule?.remoteRowCountEstimate)
      if (Number.isFinite(remoteEstimate) && remoteEstimate >= 0) {
        totalRows = remoteEstimate
      } else {
        const pageMax = Number(pageModule?.max) || 1
        if (pageMax <= 1) {
          totalRows = pageRows
        } else if (currentPage >= pageMax) {
          totalRows = ((pageMax - 1) * pageSize) + pageRows
        } else {
          totalRows = pageMax * pageSize
        }
      }
    } else {
      const activeCount = Number(table.getDataCount?.("active"))
      totalRows = Number.isFinite(activeCount) && activeCount >= 0 ? activeCount : pageRows
    }

    const hasRows = pageRows > 0 && totalRows > 0
    const start = hasRows ? (((currentPage - 1) * pageSize) + 1) : 0
    const end = hasRows ? Math.min(totalRows, (start + pageRows - 1)) : 0

    return {
      currentPage,
      pageSize,
      pageRows,
      totalRows,
      start,
      end,
      maxPage: Math.max(1, Number(pageModule?.max) || 1),
    }
  }

  const goToPage = (page) => {
    const maxPage = Number(table.modules?.page?.max) || 1
    const target = Math.max(1, Math.min(maxPage, Number(page) || 1))
    if (typeof table.setPage === "function") table.setPage(target)
  }

  const syncUi = () => {
    const stats = pageStats()

    if (metaEl) metaEl.textContent = `Page ${stats.currentPage} of ${stats.maxPage}`
    if (summaryEl) {
      summaryEl.textContent = stats.totalRows > 0
        ? `Showing ${stats.start}-${stats.end} of ${Number(stats.totalRows).toLocaleString()}`
        : "Showing 0 results"
    }
    if (pageSizeSelect) pageSizeSelect.value = String(stats.pageSize)
    if (firstBtn) firstBtn.disabled = stats.currentPage <= 1
    if (prevBtn) prevBtn.disabled = stats.currentPage <= 1
    if (nextBtn) nextBtn.disabled = stats.currentPage >= stats.maxPage
    if (lastBtn) lastBtn.disabled = stats.currentPage >= stats.maxPage
  }

  const onFirst = () => goToPage(1)
  const onPrev = () => {
    if (typeof table.previousPage === "function") {
      table.previousPage()
      return
    }
    const currentPage = Number(table.modules?.page?.page) || 1
    goToPage(currentPage - 1)
  }
  const onNext = () => {
    if (typeof table.nextPage === "function") {
      table.nextPage()
      return
    }
    const currentPage = Number(table.modules?.page?.page) || 1
    goToPage(currentPage + 1)
  }
  const onLast = () => {
    const maxPage = Number(table.modules?.page?.max) || 1
    goToPage(maxPage)
  }

  firstBtn?.addEventListener("click", onFirst)
  prevBtn?.addEventListener("click", onPrev)
  nextBtn?.addEventListener("click", onNext)
  lastBtn?.addEventListener("click", onLast)
  const onPageSizeSelect = () => {
    const nextSize = Number(pageSizeSelect?.value)
    if (!Number.isFinite(nextSize) || nextSize <= 0) return
    if (typeof table.setPageSize === "function") table.setPageSize(nextSize)
    if (typeof table.setPage === "function") table.setPage(1)
    syncUi()
  }
  pageSizeSelect?.addEventListener("change", onPageSizeSelect)

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
    pageSizeSelect?.removeEventListener("change", onPageSizeSelect)
    if (typeof table.off === "function") {
      table.off("pageLoaded", onPageLoaded)
      table.off("dataLoaded", onDataLoaded)
      table.off("renderComplete", onRenderComplete)
      table.off("pageSizeChanged", onPageSizeChanged)
    }
    if (tableEl) {
      tableEl.classList.remove("tabulator-pagination-managed")
      delete tableEl.dataset.tabulatorPaginationMode
    }
    bar.remove()
  })

  return true
}

export function installTableLifecycleMonitor(controller, table, { storageKey = null } = {}) {
  const label = storageKey || table?.element?.dataset?.tabulatorAddonId || "table"
  let loadStartedAt = 0
  let memoryInterval = null
  let memoryWarned = false

  const now = () => (window.performance?.now ? window.performance.now() : Date.now())
  const onDataLoading = () => {
    loadStartedAt = now()
  }
  const onDataLoaded = () => {
    if (!loadStartedAt) return
    const elapsed = now() - loadStartedAt
    if (elapsed >= TABLE_REFRESH_WARN_MS && tabulatorDebugWarningsEnabled()) {
      console.warn(`Tabulator table [${label}] data load took ${Math.round(elapsed)}ms`)
    }
    loadStartedAt = 0
  }

  table.on("dataLoading", onDataLoading)
  table.on("dataLoaded", onDataLoaded)

  const heap = window.performance?.memory
  if (heap && Number(heap.jsHeapSizeLimit) > 0) {
    memoryInterval = window.setInterval(() => {
      if (!controllerOwnsTable(controller, table)) return

      const used = Number(window.performance?.memory?.usedJSHeapSize) || 0
      const limit = Number(window.performance?.memory?.jsHeapSizeLimit) || 0
      if (used <= 0 || limit <= 0) return

      const usage = used / limit
      if (usage >= 0.9 && !memoryWarned) {
        memoryWarned = true
        if (tabulatorDebugWarningsEnabled()) {
          console.warn(`Tabulator table [${label}] heap usage is high (${Math.round(usage * 100)}%)`)
        }
      } else if (usage <= 0.78) {
        memoryWarned = false
      }
    }, 30000)
  }

  registerCleanup(controller, () => {
    if (typeof table.off === "function") {
      table.off("dataLoading", onDataLoading)
      table.off("dataLoaded", onDataLoaded)
    }

    if (memoryInterval) {
      window.clearInterval(memoryInterval)
    }
  })
}

export function installAdaptiveResizing(controller, table) {
  let rafId = null
  let lastHeight = null
  let pendingRedraw = false

  const redraw = () => {
    rafId = null

    if (!table || !controllerOwnsTable(controller, table)) return
    if (!tableStillMounted(table)) return
    if (!tableCanRedraw(table)) return

    try {
      const nextHeight = controller._tableHeight?.()
      const heightChanged = Boolean(nextHeight) && nextHeight !== lastHeight

      if (heightChanged && typeof table.setHeight === "function") {
        table.setHeight(nextHeight)
        lastHeight = nextHeight
      }

      if ((heightChanged || pendingRedraw) && typeof table.redraw === "function") {
        table.redraw(true)
      }
    } catch (error) {
      // During Turbo navigation/destroy, Tabulator can briefly lose internals.
      if (!tableStillMounted(table)) return
      const message = String(error?.message || "")
      if (message.includes("getBoundingClientRect")) return
      throw error
    } finally {
      pendingRedraw = false
    }
  }

  const requestRedraw = () => {
    pendingRedraw = true
    if (rafId) return
    rafId = window.requestAnimationFrame(redraw)
  }

  window.addEventListener("resize", requestRedraw, { passive: true })

  let observer
  const resizeTarget = table.element?.parentElement || table.element
  if (typeof ResizeObserver !== "undefined" && resizeTarget) {
    let lastObservedWidth = null
    observer = new ResizeObserver((entries) => {
      const width = entries?.[0]?.contentRect?.width

      if (!Number.isFinite(width)) {
        requestRedraw()
        return
      }

      if (lastObservedWidth === null) {
        lastObservedWidth = width
        requestRedraw()
        return
      }

      if (Math.abs(width - lastObservedWidth) <= 0.5) return
      lastObservedWidth = width
      requestRedraw()
    })
    observer.observe(resizeTarget)
  }

  let visibilityObserver
  if (typeof IntersectionObserver !== "undefined" && table.element) {
    visibilityObserver = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) requestRedraw()
    }, { root: null, threshold: 0.01 })
    visibilityObserver.observe(table.element)
  }

  requestRedraw()

  registerCleanup(controller, () => {
    if (rafId) window.cancelAnimationFrame(rafId)
    window.removeEventListener("resize", requestRedraw)
    observer?.disconnect()
    visibilityObserver?.disconnect()
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
  if (!consumer?.subscriptions || typeof consumer.subscriptions.create !== "function") return
  const shouldRefreshForMessage = typeof shouldRefresh === "function" ? shouldRefresh : () => true
  const refresh = typeof onRefresh === "function" ? onRefresh : () => controller.table?.replaceData()

  let refreshTimer = null
  let refreshQueued = false
  let refreshInFlight = false
  let lastRefreshAt = 0

  const scheduleRefresh = (delayMs = debounceMs) => {
    refreshQueued = true
    if (refreshTimer) window.clearTimeout(refreshTimer)

    const minGapMs = 220
    const elapsedSinceLast = Date.now() - lastRefreshAt
    const cooldownMs = elapsedSinceLast >= minGapMs ? 0 : (minGapMs - elapsedSinceLast)
    const normalizedDelayMs = Number.isFinite(Number(delayMs)) ? Number(delayMs) : debounceMs
    const nextDelayMs = Math.max(60, normalizedDelayMs, cooldownMs)

    refreshTimer = window.setTimeout(() => {
      refreshTimer = null
      runRefresh()
    }, nextDelayMs)
  }

  const runRefresh = () => {
    if (refreshInFlight) {
      refreshQueued = true
      return
    }

    if (document.visibilityState === "hidden") {
      refreshQueued = true
      return
    }

    const activeTable = controller.table || controller.tableInstance
    if (activeTable && !tableStillMounted(activeTable)) {
      refreshQueued = true
      return
    }

    refreshInFlight = true
    refreshQueued = false

    const startedAt = window.performance?.now ? window.performance.now() : Date.now()

    Promise.resolve()
      .then(() => refresh())
      .catch(() => {
        // Ignore refresh errors; future events will retry.
      })
      .finally(() => {
        const endedAt = window.performance?.now ? window.performance.now() : Date.now()
        const elapsedMs = endedAt - startedAt
        if (elapsedMs >= TABLE_REFRESH_WARN_MS && tabulatorDebugWarningsEnabled()) {
          console.warn(`Tabulator refresh for topics [${Array.from(uniqueTopics).join(", ")}] took ${Math.round(elapsedMs)}ms`)
        }

        refreshInFlight = false
        lastRefreshAt = Date.now()

        if (refreshQueued) {
          scheduleRefresh(120)
        }
      })
  }

  const onVisibilityChange = () => {
    if (document.visibilityState !== "visible") return
    if (!refreshQueued && !refreshTimer) return
    scheduleRefresh(80)
  }

  document.addEventListener("visibilitychange", onVisibilityChange, { passive: true })

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
    document.removeEventListener("visibilitychange", onVisibilityChange)
    consumer.subscriptions.remove(subscription)
  })
}
