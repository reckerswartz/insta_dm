import { Controller } from "@hotwired/stimulus"
import { getCableConsumer } from "../lib/cable_consumer"
import { notifyApp } from "../lib/notifications"

export default class extends Controller {
  static values = { accountId: Number }

  connect() {
    this.consumer = null
    this.subscription = null
    this.wsConnected = false
    this.pendingEventIds = new Set()
    this.statusPollingActive = new Set()
    this.statusPollers = new Map()
    this.statusPollCadenceMs = new Map()
    this.statusPollFailures = new Map()
    this.statusPollInFlight = new Map()
    this.statusPollLastRealtimeAt = new Map()
    this.ensureSubscription()
  }

  disconnect() {
    if (this.consumer && this.subscription) {
      this.consumer.subscriptions.remove(this.subscription)
    }
    this.clearStatusPollers()
    this.pendingEventIds.clear()
    this.wsConnected = false
  }

  async generateComment(event) {
    event.preventDefault()
    const button = event.currentTarget
    const eventId = button?.dataset?.eventId || button?.closest("[data-event-id]")?.dataset?.eventId
    if (!eventId) return
    const key = String(eventId)
    const force = String(button?.dataset?.generateForce || "").toLowerCase() === "true"
    const regenerateAll = String(button?.dataset?.generateAll || "").toLowerCase() === "true"
    if (this.pendingEventIds.has(key)) return

    try {
      this.ensureSubscription()
      this.pendingEventIds.add(key)
      this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
      this.updateButtonsForEvent(eventId, { disabled: true, label: "Queued", loading: true, eta: null, force: false })
      this.updateProgressForEvent(eventId, { status: "queued", llm_processing_stages: this.defaultQueuedStages() })
      this.emitStateChange(eventId, { status: "queued", llm_processing_stages: this.defaultQueuedStages() })
      const result = await this.callGenerateCommentApi(eventId, { force, regenerateAll })
      this.processImmediateResult(eventId, result)
    } catch (error) {
      this.pendingEventIds.delete(key)
      this.updateProgressForEvent(eventId, { status: "failed" })
      this.updateStatusDisplaysForEvent(eventId, { status: "failed" })
      this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
      this.emitStateChange(eventId, { status: "failed", error: error.message })
      notifyApp(`Failed to generate comment: ${error.message}`, "error")
    }
  }

  ensureSubscription() {
    if (!Number.isFinite(this.accountIdValue) || this.accountIdValue <= 0) return
    if (this.subscription) return

    try {
      this.consumer = getCableConsumer()
      this.subscription = this.consumer.subscriptions.create(
        {
          channel: "LlmCommentGenerationChannel",
          account_id: this.accountIdValue,
        },
        {
          connected: () => {
            this.wsConnected = true
          },
          disconnected: () => {
            this.wsConnected = false
            this.statusPollingActive.forEach((eventId) => {
              this.statusPollCadenceMs.set(String(eventId), 3000)
              this.scheduleStatusPoll(String(eventId), 1200)
            })
          },
          rejected: () => {
            this.wsConnected = false
            notifyApp("Real-time updates are unavailable. Please refresh and retry.", "error")
          },
          received: (data) => this.handleReceived(data),
        },
      )
    } catch (error) {
      // Keep queueing available, but inform user that realtime feedback cannot be guaranteed.
      this.subscription = null
      this.consumer = null
      this.wsConnected = false
      console.warn("Failed to initialize LLM comment subscription", error)
    }
  }

  async callGenerateCommentApi(eventId, { force = false, regenerateAll = false } = {}) {
    const response = await fetch(`/instagram_accounts/${this.accountIdValue}/generate_llm_comment`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCsrfToken(),
        Accept: "application/json",
      },
      body: JSON.stringify({
        event_id: eventId,
        provider: "local",
        force,
        regenerate_all: regenerateAll,
      }),
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || `Request failed (${response.status})`)
    }

    return payload
  }

  async callGenerateCommentStatusApi(eventId) {
    const response = await fetch(`/instagram_accounts/${this.accountIdValue}/generate_llm_comment`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCsrfToken(),
        Accept: "application/json",
      },
      body: JSON.stringify({
        event_id: eventId,
        provider: "local",
        status_only: true,
      }),
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || `Status request failed (${response.status})`)
    }

    return payload
  }

  processImmediateResult(eventId, result) {
    const status = String(result?.status || "").toLowerCase()
    if (status === "completed") {
      this.updateProgressForEvent(eventId, result)
      this.stopStatusPolling(eventId)
      this.handleGenerationComplete(eventId, result)
      return
    }

    if (status === "queued") {
      this.startStatusPolling(eventId)
      this.updateProgressForEvent(eventId, result)
      this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "Queued",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
        force: false,
      })
      this.emitStateChange(eventId, result)
      return
    }

    if (status === "running" || status === "started") {
      this.startStatusPolling(eventId)
      this.updateProgressForEvent(eventId, result)
      this.updateStatusDisplaysForEvent(eventId, { status: "running" })
      this.updateButtonsForEvent(eventId, {
        disabled: true,
        label: "In Progress",
        loading: true,
        eta: this.buildEtaText(result?.estimated_seconds, result?.queue_size),
        force: false,
      })
      this.emitStateChange(eventId, result)
      return
    }

    if (status === "failed" || status === "error" || status === "skipped") {
      this.updateProgressForEvent(eventId, result)
      this.stopStatusPolling(eventId)
      this.pendingEventIds.delete(String(eventId))
      this.updateStatusDisplaysForEvent(eventId, { status })
      this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
      this.emitStateChange(eventId, result)
      return
    }

    this.stopStatusPolling(eventId)
    this.pendingEventIds.delete(String(eventId))
    this.updateStatusDisplaysForEvent(eventId, { status: "not_requested" })
    this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
    this.emitStateChange(eventId, { status: "not_requested" })
  }

  handleReceived(data) {
    const eventId = String(data?.event_id || "")
    if (!eventId) return
    this.recordRealtimeUpdate(eventId)

    const status = String(data?.status || "").toLowerCase()
    switch (status) {
      case "queued":
        this.startStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "queued" })
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: "Queued",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
          force: false,
        })
        this.emitStateChange(eventId, data)
        break
      case "running":
      case "started":
        this.startStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "running" })
        this.updateButtonsForEvent(eventId, {
          disabled: true,
          label: "In Progress",
          loading: true,
          eta: this.buildEtaText(data?.estimated_seconds, data?.queue_size),
          force: false,
        })
        this.emitStateChange(eventId, data)
        break
      case "completed":
        this.stopStatusPolling(eventId)
        this.updateProgressForEvent(eventId, data)
        this.handleGenerationComplete(eventId, data)
        break
      case "skipped":
        this.stopStatusPolling(eventId)
        this.pendingEventIds.delete(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "skipped" })
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
        this.emitStateChange(eventId, data)
        notifyApp(data?.message || "Comment generation skipped: no usable local context.", "notice")
        break
      case "error":
      case "failed":
        this.stopStatusPolling(eventId)
        this.pendingEventIds.delete(eventId)
        this.updateProgressForEvent(eventId, data)
        this.updateStatusDisplaysForEvent(eventId, { status: "failed" })
        this.updateButtonsForEvent(eventId, { disabled: false, label: "Generate", loading: false, eta: null, force: false })
        this.emitStateChange(eventId, data)
        notifyApp(`Failed to generate comment: ${data?.error || data?.message || "Unknown error"}`, "error")
        break
      default:
        break
    }
  }

  handleGenerationComplete(eventId, data) {
    this.stopStatusPolling(eventId)
    this.pendingEventIds.delete(String(eventId))
    this.updateProgressForEvent(eventId, data)
    const generatedAt = data?.generated_at || data?.llm_comment_generated_at
    this.updateStatusDisplaysForEvent(eventId, { status: "completed", generatedAt })
    this.updateButtonsForEvent(eventId, { disabled: false, label: "Regenerate", loading: false, eta: null, force: true })
    this.emitStateChange(eventId, data)
    this.hydrateCompletedState(eventId, data)
    notifyApp("Comment generated successfully.", "success")
  }

  updateProgressForEvent(eventId, data) {
    const key = String(eventId || "").trim()
    if (!key) return

    const status = String(data?.status || "").toLowerCase()
    const stageMap = this.extractStageMap(data)
    let entries = this.normalizeStageEntries(stageMap)
    if (entries.length === 0 && ["queued", "running", "started"].includes(status)) {
      entries = this.normalizeStageEntries(this.defaultQueuedStages())
    }
    const lastStage = this.extractLastStage(data)

    this.findProgressContainersForEvent(key).forEach((container) => {
      this.renderStageProgress(container, entries, { lastStage, status })
    })
  }

  updateStatusDisplaysForEvent(eventId, { status, generatedAt = null } = {}) {
    const state = this.resolveUiState(status)
    document
      .querySelectorAll(`.llm-comment-section[data-event-id="${this.escapeSelector(String(eventId))}"]`)
      .forEach((section) => {
        section.dataset.llmStatus = state.code

        const statusEl = section.querySelector("[data-role='llm-status']")
        if (statusEl) {
          statusEl.textContent = state.label
          statusEl.classList.remove("queued", "in-progress", "completed", "failed", "skipped", "idle", "partial")
          statusEl.classList.add(state.chipClass)
        }

        const completionEl = section.querySelector("[data-role='llm-completion']")
        if (completionEl) {
          if (state.code === "completed") {
            completionEl.classList.remove("hidden")
            completionEl.textContent = `Completed ${this.formatDate(generatedAt)}`
          } else {
            completionEl.classList.add("hidden")
          }
        }
      })
  }

  resolveUiState(status) {
    const normalizedStatus = String(status || "").toLowerCase()
    if (normalizedStatus === "completed" || normalizedStatus === "ready") {
      return { code: "completed", label: "Completed", chipClass: "completed" }
    }
    if (normalizedStatus === "partial") {
      return { code: "partial", label: "Partial", chipClass: "in-progress" }
    }
    if (normalizedStatus === "queued") {
      return { code: "queued", label: "Queued", chipClass: "queued" }
    }
    if (normalizedStatus === "running" || normalizedStatus === "started" || normalizedStatus === "processing") {
      return { code: "in_progress", label: "In Progress", chipClass: "in-progress" }
    }
    if (normalizedStatus === "failed" || normalizedStatus === "error") {
      return { code: "failed", label: "Failed", chipClass: "failed" }
    }
    if (normalizedStatus === "skipped") {
      return { code: "skipped", label: "Skipped", chipClass: "skipped" }
    }
    return { code: "not_started", label: "Ready", chipClass: "idle" }
  }

  findProgressContainersForEvent(eventId) {
    const escaped = this.escapeSelector(String(eventId))
    return Array.from(document.querySelectorAll(`.llm-comment-section[data-event-id="${escaped}"]`))
  }

  renderStageProgress(container, entries, { lastStage = null, status = "" } = {}) {
    if (!container) return

    const activeStatus = ["queued", "running", "started", "completed", "failed", "error", "skipped"].includes(String(status))
    const summaryText = this.buildCompactProgressSummary(entries, status)
    if (!activeStatus && !summaryText) {
      const existingSummary = container.querySelector("[data-role='llm-progress-compact']")
      if (existingSummary) {
        existingSummary.textContent = ""
        existingSummary.classList.add("hidden")
      }
      return
    }

    let summaryEl = container.querySelector("[data-role='llm-progress-compact']")
    if (!summaryEl) {
      summaryEl = document.createElement("p")
      summaryEl.className = "meta llm-progress-compact"
      summaryEl.dataset.role = "llm-progress-compact"
      container.appendChild(summaryEl)
    }
    summaryEl.textContent = summaryText
    summaryEl.classList.toggle("hidden", !summaryText)

    let lastStageEl = container.querySelector("[data-role='llm-stage-last']")
    if (!lastStageEl) {
      lastStageEl = document.createElement("p")
      lastStageEl.className = "meta llm-stage-last hidden"
      lastStageEl.dataset.role = "llm-stage-last"
      container.appendChild(lastStageEl)
    }

    const lastStageText = this.formatLastStageText(lastStage)
    if (lastStageText) {
      lastStageEl.textContent = `Latest: ${lastStageText}`
      lastStageEl.classList.remove("hidden")
    } else {
      lastStageEl.textContent = ""
      lastStageEl.classList.add("hidden")
    }
  }

  buildCompactProgressSummary(entries, status) {
    const normalizedStatus = String(status || "").toLowerCase()
    if (normalizedStatus === "not_requested" || normalizedStatus === "") return ""

    const phaseStates = this.phaseStates(entries)
    const total = phaseStates.length
    const completed = phaseStates.filter((row) => row.state === "completed").length
    const failed = phaseStates.some((row) => row.state === "failed")

    if (normalizedStatus === "completed") return `${total} of ${total} completed`
    if (normalizedStatus === "skipped") return `${completed} of ${total} completed (skipped)`
    if (normalizedStatus === "failed" || normalizedStatus === "error" || failed) {
      return `${completed} of ${total} completed (failed)`
    }
    if (normalizedStatus === "queued") return `${completed} of ${total} completed (queued)`
    return `${completed} of ${total} completed`
  }

  phaseStates(entries) {
    const stateByKey = new Map()
    entries.forEach((entry) => stateByKey.set(String(entry.key), String(entry.state || "pending").toLowerCase()))

    const phases = [
      ["analysis", ["parallel_services", "ocr_analysis", "vision_detection", "metadata_extraction"]],
      ["context", ["context_matching", "prompt_construction"]],
      ["generation", ["llm_generation", "relevance_scoring"]],
      ["eligibility", ["engagement_eligibility"]],
      ["send", ["reply_send_action"]],
    ]

    return phases.map(([, keys]) => {
      const states = keys.map((key) => stateByKey.get(key) || "pending")
      if (states.some((state) => state === "failed" || state === "error")) return { state: "failed" }
      if (states.every((state) => state === "completed" || state === "completed_with_warnings" || state === "skipped")) return { state: "completed" }
      if (states.some((state) => state === "running" || state === "started" || state === "queued")) return { state: "running" }
      return { state: "pending" }
    })
  }

  extractStageMap(data) {
    const fromRequest = data?.llm_processing_stages && typeof data.llm_processing_stages === "object" ? data.llm_processing_stages : {}
    const fromBroadcast = data?.stage_statuses && typeof data.stage_statuses === "object" ? data.stage_statuses : {}
    return this.mergeStageMaps(fromBroadcast, fromRequest)
  }

  mergeStageMaps(primary, secondary) {
    const merged = {}
    const merge = (input) => {
      if (!input || typeof input !== "object") return
      Object.entries(input).forEach(([key, row]) => {
        if (!row || typeof row !== "object") return
        const current = merged[key] && typeof merged[key] === "object" ? merged[key] : {}
        merged[key] = { ...current, ...row }
      })
    }
    merge(primary)
    merge(secondary)
    return merged
  }

  normalizeStageEntries(stageMap) {
    if (!stageMap || typeof stageMap !== "object") return []
    return Object.entries(stageMap)
      .filter(([, row]) => row && typeof row === "object")
      .map(([key, row]) => {
        const label = String(row?.label || this.humanizeStageKey(key))
        const state = String(row?.state || "pending").toLowerCase()
        const progress = Number(row?.progress)
        const providedOrder = Number(row?.order)
        return {
          key: String(key),
          label: label || "Stage",
          state,
          progress: Number.isFinite(progress) ? progress : null,
          order: Number.isFinite(providedOrder) ? providedOrder : this.stageSortWeight(key),
        }
      })
      .sort((a, b) => {
        if (a.order !== b.order) return a.order - b.order
        return a.label.localeCompare(b.label)
      })
  }

  stageSortWeight(stageKey) {
    const order = {
      queue_wait: 5,
      parallel_services: 10,
      video_analysis: 12,
      audio_extraction: 14,
      speech_transcription: 16,
      ocr_analysis: 20,
      vision_detection: 24,
      face_recognition: 28,
      metadata_extraction: 32,
      context_matching: 40,
      prompt_construction: 50,
      llm_generation: 60,
      relevance_scoring: 70,
      engagement_eligibility: 80,
      reply_send_action: 90,
    }
    return Number(order[String(stageKey)] || 900)
  }

  resolveStageVisual(state, progress) {
    const normalized = String(state || "pending").toLowerCase()
    if (normalized === "completed") {
      return { className: "stage-completed", label: "Completed", icon: "done" }
    }
    if (normalized === "completed_with_warnings") {
      return { className: "stage-warning", label: "Completed (Warnings)", icon: "warn" }
    }
    if (normalized === "running" || normalized === "started") {
      const suffix = Number.isFinite(progress) ? ` (${Math.round(progress)}%)` : ""
      return { className: "stage-running", label: `In Progress${suffix}`, icon: "run" }
    }
    if (normalized === "queued") {
      return { className: "stage-queued", label: "Queued", icon: "queue" }
    }
    if (normalized === "failed" || normalized === "error") {
      return { className: "stage-failed", label: "Failed", icon: "fail" }
    }
    if (normalized === "skipped") {
      return { className: "stage-skipped", label: "Skipped", icon: "skip" }
    }
    return { className: "stage-pending", label: "Pending", icon: "wait" }
  }

  extractLastStage(data) {
    const explicit = data?.llm_last_stage
    if (explicit && typeof explicit === "object") return explicit

    if (String(data?.stage || "").trim().length > 0 || String(data?.message || "").trim().length > 0) {
      return {
        stage: data?.stage,
        state: data?.status,
        message: data?.message,
        at: data?.at || data?.updated_at || null,
      }
    }

    return null
  }

  formatLastStageText(row) {
    if (!row || typeof row !== "object") return ""
    const stage = String(row?.stage || row?.label || "").trim()
    const state = String(row?.state || "").trim().toLowerCase()
    const message = String(row?.message || "").trim()
    const timeValue = row?.at || row?.updated_at || null

    const stageText = stage ? this.humanizeStageKey(stage) : ""
    const stateText = this.resolveStageVisual(state).label
    const at = this.formatDate(timeValue)
    const segments = []
    if (stageText) segments.push(stageText)
    if (stateText && stateText !== "Pending") segments.push(stateText)
    if (message) segments.push(message)
    if (at !== "-") segments.push(at)
    return segments.join(" | ")
  }

  emitStateChange(eventId, data) {
    const detail = this.buildArchivePatch(eventId, data)
    if (!detail) return
    window.dispatchEvent(new CustomEvent("llm-comment:state-changed", { detail }))
  }

  buildArchivePatch(eventId, data) {
    const key = String(eventId || "").trim()
    if (!key) return null

    const stageMap = this.extractStageMap(data)
    const normalizedStatus = this.normalizeArchiveStatus(data?.llm_workflow_status || data?.status)
    const rankedFromResult = Array.isArray(data?.generation_result?.ranked_candidates) ? data.generation_result.ranked_candidates : []
    const rankedCandidates = Array.isArray(data?.llm_ranked_candidates) ? data.llm_ranked_candidates : rankedFromResult
    const comment = [data?.llm_generated_comment, data?.comment, data?.generation_result?.selected_comment]
      .map((value) => String(value || "").trim())
      .find((value) => value.length > 0)
    const generatedAt = data?.llm_comment_generated_at || data?.generated_at || null
    const processingLog = Array.isArray(data?.llm_processing_log) ? data.llm_processing_log : []
    const pipelineStepRollup = data?.llm_pipeline_step_rollup && typeof data.llm_pipeline_step_rollup === "object" ? data.llm_pipeline_step_rollup : null
    const pipelineTiming = data?.llm_pipeline_timing && typeof data.llm_pipeline_timing === "object" ? data.llm_pipeline_timing : null
    const relevanceBreakdown = data?.llm_relevance_breakdown || data?.relevance_breakdown || data?.generation_result?.relevance_breakdown
    const relevanceScore = data?.llm_comment_relevance_score ?? data?.relevance_score ?? data?.generation_result?.relevance_score
    const failureMessage = String(data?.error || data?.llm_comment_last_error || data?.llm_failure_message || data?.message || "").trim()
    const generationPolicy = data?.llm_generation_policy && typeof data.llm_generation_policy === "object" ? data.llm_generation_policy : null
    const failureReasonCode = String(data?.llm_failure_reason_code || data?.reason || "").trim()
    const failureSource = String(data?.llm_failure_source || data?.source || "").trim()
    const failureErrorClass = String(data?.llm_failure_error_class || "").trim()
    const manualReviewReason = String(data?.llm_manual_review_reason || "").trim()
    const policyReasonCode = String(data?.llm_policy_reason_code || generationPolicy?.reason_code || "").trim()
    const policyReason = String(data?.llm_policy_reason || generationPolicy?.reason || "").trim()
    const policySource = String(data?.llm_policy_source || generationPolicy?.source || "").trim()
    const hasPolicyAllow = Object.prototype.hasOwnProperty.call(data || {}, "llm_policy_allow_comment")
    const policyAllow = hasPolicyAllow ? this.coerceBoolean(data?.llm_policy_allow_comment) : null
    const hasAutoPostAllowed = Object.prototype.hasOwnProperty.call(data || {}, "llm_auto_post_allowed")
    const autoPostAllowed = hasAutoPostAllowed ? this.coerceBoolean(data?.llm_auto_post_allowed) : null
    const modelLabel = String(data?.llm_model_label || "").trim()

    const patch = {}
    if (normalizedStatus) patch.llm_comment_status = normalizedStatus
    if (comment) {
      patch.llm_generated_comment = comment
      patch.has_llm_comment = true
    }
    if (generatedAt) patch.llm_comment_generated_at = generatedAt
    if (String(data?.llm_comment_model || data?.model || "").trim()) patch.llm_comment_model = String(data?.llm_comment_model || data?.model)
    if (String(data?.llm_comment_provider || data?.provider || "").trim()) patch.llm_comment_provider = String(data?.llm_comment_provider || data?.provider)
    if (modelLabel) patch.llm_model_label = modelLabel
    if (Number.isFinite(Number(relevanceScore))) patch.llm_comment_relevance_score = Number(relevanceScore)
    if (relevanceBreakdown && typeof relevanceBreakdown === "object") patch.llm_relevance_breakdown = relevanceBreakdown
    if (rankedCandidates.length > 0) patch.llm_ranked_candidates = rankedCandidates
    if (Object.keys(stageMap).length > 0) patch.llm_processing_stages = stageMap
    if (processingLog.length > 0) patch.llm_processing_log = processingLog
    if (pipelineStepRollup && Object.keys(pipelineStepRollup).length > 0) patch.llm_pipeline_step_rollup = pipelineStepRollup
    if (pipelineTiming && Object.keys(pipelineTiming).length > 0) patch.llm_pipeline_timing = pipelineTiming
    if (manualReviewReason) patch.llm_manual_review_reason = manualReviewReason
    if (hasAutoPostAllowed) patch.llm_auto_post_allowed = autoPostAllowed
    if (generationPolicy && Object.keys(generationPolicy).length > 0) patch.llm_generation_policy = generationPolicy
    if (failureReasonCode) patch.llm_failure_reason_code = failureReasonCode
    if (failureSource) patch.llm_failure_source = failureSource
    if (failureErrorClass) patch.llm_failure_error_class = failureErrorClass
    if (hasPolicyAllow) patch.llm_policy_allow_comment = policyAllow
    if (policyReasonCode) patch.llm_policy_reason_code = policyReasonCode
    if (policyReason) patch.llm_policy_reason = policyReason
    if (policySource) patch.llm_policy_source = policySource
    if (["failed", "skipped"].includes(normalizedStatus) && failureMessage) {
      patch.llm_comment_last_error = failureMessage
      patch.llm_comment_last_error_preview = failureMessage.slice(0, 180)
      patch.llm_failure_message = failureMessage
    } else if (normalizedStatus === "completed") {
      patch.llm_comment_last_error = null
      patch.llm_comment_last_error_preview = null
      if (manualReviewReason) {
        patch.llm_failure_message = manualReviewReason
      } else if (policyReason) {
        patch.llm_failure_message = policyReason
      }
    }
    if (String(data?.llm_workflow_status || "").trim().length > 0) patch.llm_workflow_status = String(data.llm_workflow_status)
    if (data?.llm_workflow_progress && typeof data.llm_workflow_progress === "object") patch.llm_workflow_progress = data.llm_workflow_progress

    return { eventId: key, patch, status: normalizedStatus }
  }

  hydrateCompletedState(eventId, data) {
    const hasComment = String(data?.llm_generated_comment || data?.comment || "").trim().length > 0
    const hasCandidates = Array.isArray(data?.llm_ranked_candidates) && data.llm_ranked_candidates.length > 0
    const hasTiming = data?.llm_pipeline_timing && typeof data.llm_pipeline_timing === "object"
    if (hasComment && hasCandidates && hasTiming) return

    const key = String(eventId || "").trim()
    if (!key) return

    this.callGenerateCommentStatusApi(key)
      .then((payload) => {
        if (String(payload?.status || "").toLowerCase() !== "completed") return
        this.emitStateChange(key, payload)
      })
      .catch(() => {})
  }

  normalizeArchiveStatus(status) {
    const normalized = String(status || "").toLowerCase()
    if (normalized === "started") return "running"
    if (normalized === "error") return "failed"
    if (["queued", "running", "completed", "failed", "skipped", "processing", "partial", "ready"].includes(normalized)) return normalized
    return normalized || "not_requested"
  }

  defaultQueuedStages() {
    return {
      queue_wait: { label: "Queue Wait", state: "queued", progress: 0, order: 5 },
      parallel_services: { label: "Parallel Stage Jobs", state: "pending", progress: 0, order: 10 },
      ocr_analysis: { label: "OCR Analysis", state: "pending", progress: 0, order: 20 },
      vision_detection: { label: "Video/Image Analysis", state: "pending", progress: 0, order: 24 },
      face_recognition: { label: "Face Recognition (Deferred)", state: "pending", progress: 0, order: 28 },
      metadata_extraction: { label: "Metadata Extraction", state: "pending", progress: 0, order: 32 },
      context_matching: { label: "Context Matching", state: "pending", progress: 0, order: 40 },
      prompt_construction: { label: "Prompt Construction", state: "pending", progress: 0, order: 50 },
      llm_generation: { label: "Comment Generation", state: "pending", progress: 0, order: 60 },
      relevance_scoring: { label: "Relevance Scoring", state: "pending", progress: 0, order: 70 },
      engagement_eligibility: { label: "Engagement Eligibility", state: "pending", progress: 0, order: 80 },
      reply_send_action: { label: "Reply Send Action", state: "pending", progress: 0, order: 90 },
    }
  }

  humanizeStageKey(value) {
    const key = String(value || "").trim()
    if (!key) return "Stage"
    return key
      .replace(/[_-]+/g, " ")
      .split(" ")
      .filter(Boolean)
      .map((token) => token.charAt(0).toUpperCase() + token.slice(1))
      .join(" ")
  }

  startStatusPolling(eventId) {
    const key = String(eventId)
    if (this.statusPollingActive.has(key)) return

    this.statusPollingActive.add(key)
    this.statusPollFailures.set(key, 0)
    this.statusPollCadenceMs.set(key, this.wsConnected ? 9000 : 3000)
    this.scheduleStatusPoll(key, this.statusPollCadenceMs.get(key))
  }

  scheduleStatusPoll(eventId, delayMs) {
    const key = String(eventId)
    if (!this.statusPollingActive.has(key)) return

    const existing = this.statusPollers.get(key)
    if (existing) {
      clearTimeout(existing)
      this.statusPollers.delete(key)
    }

    const timeoutMs = Number.isFinite(Number(delayMs)) ? Math.max(1000, Math.round(Number(delayMs))) : 3000
    const timer = window.setTimeout(async () => {
      this.statusPollers.delete(key)
      if (!this.statusPollingActive.has(key)) return

      if (this.shouldDeferPollForRealtime(key)) {
        this.scheduleStatusPoll(key, this.nextPollDelayMs(key, { realtimeDeferral: true }))
        return
      }

      if (this.statusPollInFlight.get(key)) {
        this.scheduleStatusPoll(key, this.nextPollDelayMs(key, { realtimeDeferral: true }))
        return
      }

      this.statusPollInFlight.set(key, true)
      try {
        const result = await this.callGenerateCommentStatusApi(key)
        this.statusPollFailures.set(key, 0)
        this.processImmediateResult(key, result)
        if (this.statusPollingActive.has(key)) {
          this.scheduleStatusPoll(key, this.nextPollDelayMs(key, { status: result?.status }))
        }
      } catch (error) {
        const failures = Number(this.statusPollFailures.get(key) || 0) + 1
        this.statusPollFailures.set(key, failures)
        if (failures >= 4) {
          this.stopStatusPolling(key)
          notifyApp("Unable to verify comment generation status. Please refresh the archive.", "error")
        } else if (this.statusPollingActive.has(key)) {
          this.scheduleStatusPoll(key, this.nextPollDelayMs(key, { failed: true }))
        }
      } finally {
        this.statusPollInFlight.set(key, false)
      }
    }, timeoutMs)

    this.statusPollers.set(key, timer)
  }

  shouldDeferPollForRealtime(eventId) {
    if (!this.wsConnected) return false
    const lastUpdateAt = Number(this.statusPollLastRealtimeAt.get(String(eventId)) || 0)
    if (!Number.isFinite(lastUpdateAt) || lastUpdateAt <= 0) return false
    return Date.now() - lastUpdateAt < 12000
  }

  nextPollDelayMs(eventId, { status = "", failed = false, realtimeDeferral = false } = {}) {
    const key = String(eventId)
    const normalizedStatus = String(status || "").toLowerCase()
    const current = Number(this.statusPollCadenceMs.get(key) || (this.wsConnected ? 9000 : 3000))
    let nextDelay = current

    if (failed) {
      nextDelay = Math.min(Math.round(current * 1.7), 30000)
    } else if (realtimeDeferral) {
      nextDelay = Math.min(Math.round(Math.max(current, 7000) * 1.25), 30000)
    } else if (this.wsConnected) {
      const floor = normalizedStatus === "queued" ? 9000 : 11000
      nextDelay = Math.min(Math.max(current, floor) + 1500, 30000)
    } else {
      nextDelay = Math.min(Math.round(Math.max(current, 3000) * 1.35), 15000)
    }

    this.statusPollCadenceMs.set(key, nextDelay)
    return nextDelay
  }

  recordRealtimeUpdate(eventId) {
    this.statusPollLastRealtimeAt.set(String(eventId), Date.now())
  }

  stopStatusPolling(eventId) {
    const key = String(eventId)
    this.statusPollingActive.delete(key)
    const timer = this.statusPollers.get(key)
    if (timer) {
      clearTimeout(timer)
      this.statusPollers.delete(key)
    }
    this.statusPollCadenceMs.delete(key)
    this.statusPollFailures.delete(key)
    this.statusPollInFlight.delete(key)
    this.statusPollLastRealtimeAt.delete(key)
  }

  clearStatusPollers() {
    this.statusPollers.forEach((timer) => clearTimeout(timer))
    this.statusPollingActive.clear()
    this.statusPollers.clear()
    this.statusPollCadenceMs.clear()
    this.statusPollFailures.clear()
    this.statusPollInFlight.clear()
    this.statusPollLastRealtimeAt.clear()
  }

  updateButtonsForEvent(eventId, state) {
    const escapedEventId = this.escapeSelector(String(eventId))
    document
      .querySelectorAll(`.generate-comment-btn[data-event-id="${escapedEventId}"]`)
      .forEach((button) => this.updateButtonState(button, state))
    document
      .querySelectorAll(`.generate-comment-all-btn[data-event-id="${escapedEventId}"]`)
      .forEach((button) => {
        const loading = Boolean(state?.loading)
        this.updateButtonState(button, {
          ...state,
          label: loading ? String(state?.label || "Queued") : "Regenerate All",
          force: true,
        })
      })
  }

  updateButtonState(button, { disabled, label, loading, eta = null, force = null }) {
    if (!button) return
    button.disabled = Boolean(disabled)
    button.classList.toggle("loading", Boolean(loading))
    if (typeof label === "string" && label.length > 0) {
      button.textContent = label
    }
    if (typeof force === "boolean") {
      button.dataset.generateForce = force ? "true" : "false"
    }

    const container = button.closest(".llm-comment-section, .story-modal-section") || button.parentElement
    if (!container) return
    const existing = container.querySelector(".llm-progress-hint")
    if (eta) {
      if (existing) {
        existing.textContent = eta
      } else {
        const hint = document.createElement("p")
        hint.className = "meta llm-progress-hint"
        hint.textContent = eta
        container.appendChild(hint)
      }
    } else if (existing) {
      existing.remove()
    }
  }

  buildEtaText(seconds, queueSize) {
    const sec = Number(seconds)
    if (!Number.isFinite(sec) || sec <= 0) return null
    const rangeLow = Math.max(5, Math.floor(sec * 0.7))
    const rangeHigh = Math.ceil(sec * 1.5)
    const queue = Number.isFinite(Number(queueSize)) ? ` (queue: ${Number(queueSize)})` : ""
    return `Estimated ${rangeLow}-${rangeHigh}s${queue}`
  }

  formatDate(value) {
    if (!value) return "-"
    const date = new Date(value)
    return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString()
  }

  getCsrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }

  escapeSelector(value) {
    if (typeof window.CSS !== "undefined" && typeof window.CSS.escape === "function") {
      return window.CSS.escape(String(value))
    }
    return String(value).replaceAll('"', '\\"')
  }

  esc(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }

  coerceBoolean(value) {
    if (typeof value === "boolean") return value
    const normalized = String(value || "").toLowerCase().trim()
    if (["1", "true", "yes", "on"].includes(normalized)) return true
    if (["0", "false", "no", "off"].includes(normalized)) return false
    return Boolean(value)
  }
}
