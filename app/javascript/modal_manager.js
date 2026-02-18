class ModalManager {
  constructor() {
    this.modal = null
    this.loadingModal = null
    this.ready = false
  }

  init() {
    const universalEl = document.getElementById("universalModal")
    const loadingEl = document.getElementById("loadingModal")
    if (!universalEl || !loadingEl || !window.bootstrap) return

    this.modal = bootstrap.Modal.getOrCreateInstance(universalEl)
    this.loadingModal = bootstrap.Modal.getOrCreateInstance(loadingEl)
    this.ready = true

    universalEl.addEventListener("hidden.bs.modal", () => {
      this.resetModal()
    })

    this.bindConfirmForms()
  }

  bindConfirmForms() {
    if (document.body.dataset.confirmModalBound === "1") return
    document.body.dataset.confirmModalBound = "1"

    document.addEventListener("submit", (event) => {
      const form = event.target
      if (!(form instanceof HTMLFormElement)) return
      if (!form.dataset.confirmModal) return
      if (form.dataset.confirmed === "1") return

      event.preventDefault()
      const title = form.dataset.confirmTitle || "Please confirm"
      const message = form.dataset.confirmMessage || "Are you sure you want to continue?"
      const loadingText = form.dataset.modalLoadingText

      this.confirm(title, message, () => {
        form.dataset.confirmed = "1"
        if (loadingText) this.showLoading(loadingText)
        form.requestSubmit()
        setTimeout(() => {
          delete form.dataset.confirmed
        }, 100)
      })
    })
  }

  confirm(title, message, onConfirm, options = {}) {
    const template = document.getElementById("confirmationModalTemplate")
    if (!template) return

    const content = template.innerHTML
      .replace("{{title}}", this.escapeHtml(title))
      .replace("{{message}}", this.escapeHtml(message))

    this.showModal(content, {
      size: options.size || "modal-sm",
      backdrop: options.backdrop ?? true,
      keyboard: options.keyboard ?? true,
      hideFooter: true
    })

    const confirmBtn = document.querySelector("#confirmAction")
    if (confirmBtn) {
      confirmBtn.onclick = () => {
        this.hideModal()
        if (typeof onConfirm === "function") onConfirm()
      }
    }
  }

  success(title, message, options = {}) {
    const template = document.getElementById("successModalTemplate")
    if (!template) return

    const content = template.innerHTML
      .replace("{{title}}", this.escapeHtml(title))
      .replace("{{message}}", this.escapeHtml(message))

    this.showModal(content, {
      size: options.size || "modal-sm",
      backdrop: options.backdrop ?? true,
      keyboard: options.keyboard ?? true,
      hideFooter: true
    })

    if (options.autoHide !== false) {
      setTimeout(() => this.hideModal(), options.duration || 2200)
    }
  }

  error(title, message, options = {}) {
    const template = document.getElementById("errorModalTemplate")
    if (!template) return

    const content = template.innerHTML
      .replace("{{title}}", this.escapeHtml(title))
      .replace("{{message}}", this.escapeHtml(message))

    this.showModal(content, {
      size: options.size || "modal-sm",
      backdrop: options.backdrop ?? true,
      keyboard: options.keyboard ?? true,
      hideFooter: true
    })
  }

  showModal(content, options = {}) {
    if (!this.ready) return

    const modalEl = document.getElementById("universalModal")
    const modalBody = modalEl.querySelector(".modal-body")
    const modalDialog = modalEl.querySelector(".modal-dialog")
    const modalFooter = modalEl.querySelector(".modal-footer")

    modalBody.innerHTML = content
    modalDialog.className = `modal-dialog modal-dialog-centered ${options.size || ""}`.trim()
    modalFooter.style.display = options.hideFooter ? "none" : ""

    modalEl.setAttribute("data-bs-backdrop", options.backdrop ? "true" : "static")
    modalEl.setAttribute("data-bs-keyboard", options.keyboard ? "true" : "false")

    this.modal.show()
  }

  hideModal() {
    if (!this.ready) return
    this.modal.hide()
  }

  showLoading(message = "Processing...") {
    if (!this.ready) return
    const loadingMessageEl = document.getElementById("loadingMessage")
    if (loadingMessageEl) loadingMessageEl.textContent = message
    this.loadingModal.show()
  }

  hideLoading() {
    if (!this.ready) return
    this.loadingModal.hide()
  }

  resetModal() {
    const modalEl = document.getElementById("universalModal")
    if (!modalEl) return

    const modalBody = modalEl.querySelector(".modal-body")
    const modalDialog = modalEl.querySelector(".modal-dialog")
    const modalTitle = modalEl.querySelector(".modal-title")
    const modalFooter = modalEl.querySelector(".modal-footer")

    modalBody.innerHTML = ""
    modalTitle.textContent = "Modal"
    modalDialog.className = "modal-dialog modal-dialog-centered"
    modalFooter.style.display = ""

    modalEl.setAttribute("data-bs-backdrop", "true")
    modalEl.setAttribute("data-bs-keyboard", "true")
  }

  escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}

let modalManager

function bootModalManager() {
  modalManager = new ModalManager()
  modalManager.init()
  window.modalManager = modalManager

  window.showConfirmModal = (title, message, onConfirm, options) => {
    modalManager.confirm(title, message, onConfirm, options)
  }

  window.showSuccessModal = (title, message, options) => {
    modalManager.success(title, message, options)
  }

  window.showErrorModal = (title, message, options) => {
    modalManager.error(title, message, options)
  }

  window.showLoadingModal = (message) => {
    modalManager.showLoading(message)
  }

  window.hideLoadingModal = () => {
    modalManager.hideLoading()
  }
}

document.addEventListener("turbo:load", bootModalManager)
